// The C ABI in fl_crashpad.h, over Crashpad's client.
//
// Everything platform-specific about *using* Crashpad is in this one file —
// path encoding, how a handler is checked before it is trusted, what "dump
// without crashing" is called on each OS — so that no Flutter runner and no
// per-platform plugin code ever has to talk to Crashpad directly.

#define FL_CRASHPAD_IMPLEMENTATION 1
#include "fl_crashpad.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "base/files/file_path.h"
#include "build/build_config.h"
#include "client/crash_report_database.h"
#include "client/crashpad_client.h"
#include "client/crashpad_info.h"
#include "client/settings.h"
#include "client/simple_string_dictionary.h"
#include "client/simulate_crash.h"
#include "handler/minidump_to_upload_parameters.h"
#include "snapshot/minidump/process_snapshot_minidump.h"
#include "util/file/file_reader.h"
#include "util/misc/metrics.h"
#include "util/misc/uuid.h"

#if BUILDFLAG(IS_WIN)
#include <windows.h>

#include "base/strings/utf_string_conversions.h"
#else
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char** environ;
#endif

#if BUILDFLAG(IS_ANDROID)
#include <android/api-level.h>
#include <dlfcn.h>
#endif

#ifndef FL_CRASHPAD_CRASHPAD_REVISION
#error "FL_CRASHPAD_CRASHPAD_REVISION must be defined by the build"
#endif

namespace {

using crashpad::CrashpadClient;
using crashpad::CrashReportDatabase;
using crashpad::SimpleStringDictionary;
using crashpad::UUID;

// ---------------------------------------------------------------------------
// Small helpers

// Hands a message back through the C ABI's `char** error`, allocated with
// malloc so the caller releases it with fl_crashpad_free.
int32_t Fail(char** error, fl_crashpad_status status, const std::string& why) {
  if (error != nullptr) {
    char* copy = static_cast<char*>(malloc(why.size() + 1));
    if (copy != nullptr) {
      memcpy(copy, why.c_str(), why.size() + 1);
    }
    *error = copy;
  }
  return status;
}

char* Duplicate(const std::string& value) {
  char* copy = static_cast<char*>(malloc(value.size() + 1));
  if (copy != nullptr) {
    memcpy(copy, value.c_str(), value.size() + 1);
  }
  return copy;
}

base::FilePath PathFromUtf8(const char* utf8) {
#if BUILDFLAG(IS_WIN)
  return base::FilePath(base::UTF8ToWide(utf8));
#else
  return base::FilePath(utf8);
#endif
}

std::string Utf8FromPath(const base::FilePath& path) {
#if BUILDFLAG(IS_WIN)
  return base::WideToUTF8(path.value());
#else
  return path.value();
#endif
}

bool IsSet(const char* value) {
  return value != nullptr && value[0] != '\0';
}

void AppendJsonString(std::string* out, const std::string& value) {
  out->push_back('"');
  for (unsigned char c : value) {
    switch (c) {
      case '"':
        out->append("\\\"");
        break;
      case '\\':
        out->append("\\\\");
        break;
      case '\n':
        out->append("\\n");
        break;
      case '\r':
        out->append("\\r");
        break;
      case '\t':
        out->append("\\t");
        break;
      default:
        if (c < 0x20) {
          static const char kHex[] = "0123456789abcdef";
          out->append("\\u00");
          out->push_back(kHex[c >> 4]);
          out->push_back(kHex[c & 0xf]);
        } else {
          out->push_back(static_cast<char>(c));
        }
    }
  }
  out->push_back('"');
}

// ---------------------------------------------------------------------------
// The handler, checked before it is trusted
//
// Desktop only. On Android the handler is this very library, so it cannot be
// from another build; on iOS there is none.

#if !BUILDFLAG(IS_ANDROID) && !BUILDFLAG(IS_IOS)
bool FileExists(const base::FilePath& path) {
#if BUILDFLAG(IS_WIN)
  DWORD attributes = GetFileAttributesW(path.value().c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         !(attributes & FILE_ATTRIBUTE_DIRECTORY);
#else
  return access(path.value().c_str(), F_OK) == 0;
#endif
}

// Reads the revision stamp written beside the handler by the build, or an
// empty string if there is none — a handler supplied by hand need not have
// one, and is then taken on trust.
std::string ReadRevisionStamp(const base::FilePath& handler) {
  base::FilePath stamp =
      handler.DirName().Append(FILE_PATH_LITERAL("crashpad_handler.rev"));
#if BUILDFLAG(IS_WIN)
  FILE* file = _wfopen(stamp.value().c_str(), L"rb");
#else
  FILE* file = fopen(stamp.value().c_str(), "rb");
#endif
  if (file == nullptr) {
    return std::string();
  }
  char buffer[128] = {};
  size_t read = fread(buffer, 1, sizeof(buffer) - 1, file);
  fclose(file);
  std::string revision(buffer, read);
  while (!revision.empty() &&
         (revision.back() == '\n' || revision.back() == '\r' ||
          revision.back() == ' ')) {
    revision.pop_back();
  }
  return revision;
}

#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)
// Runs `handler --version` and waits up to five seconds for a clean exit.
//
// Crashpad's Linux StartHandler double-forks and execs the handler, and
// returns true without knowing whether the exec worked. A handler that is
// present but cannot run — a wrong architecture, a missing shared library, a
// noexec mount — would leave the app believing it is covered while every crash is
// lost. One cheap run at start turns that into an error somebody sees.
bool HandlerRuns(const base::FilePath& handler, std::string* why) {
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null",
                                   O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  std::string path = handler.value();
  char version[] = "--version";
  char* argv[] = {const_cast<char*>(path.c_str()), version, nullptr};
  pid_t pid = 0;
  int spawned = posix_spawn(&pid, path.c_str(), &actions, nullptr, argv,
                            environ);
  posix_spawn_file_actions_destroy(&actions);
  if (spawned != 0) {
    *why = std::string("could not run it: ") + strerror(spawned);
    return false;
  }

  for (int waited_ms = 0; waited_ms < 5000; waited_ms += 10) {
    int status = 0;
    pid_t done = waitpid(pid, &status, WNOHANG);
    if (done == pid) {
      if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        return true;
      }
      if (WIFEXITED(status) && WEXITSTATUS(status) == 127) {
        *why = "it exited 127, which usually means a shared library it links "
               "against is missing";
      } else if (WIFEXITED(status)) {
        *why = "`--version` exited " + std::to_string(WEXITSTATUS(status));
      } else {
        *why = "`--version` was killed by signal " +
               std::to_string(WTERMSIG(status));
      }
      return false;
    }
    if (done < 0) {
      *why = std::string("waitpid: ") + strerror(errno);
      return false;
    }
    struct timespec pause = {0, 10 * 1000 * 1000};
    nanosleep(&pause, nullptr);
  }
  kill(pid, SIGKILL);
  waitpid(pid, nullptr, 0);
  *why = "`--version` did not exit within five seconds";
  return false;
}
#endif

int32_t CheckHandler(const base::FilePath& handler, char** error) {
  const std::string shown = Utf8FromPath(handler);
  if (!FileExists(handler)) {
    return Fail(error, FL_CRASHPAD_HANDLER_MISSING,
                "crashpad_handler is not at " + shown);
  }
#if !BUILDFLAG(IS_WIN)
  if (access(handler.value().c_str(), X_OK) != 0) {
    return Fail(error, FL_CRASHPAD_HANDLER_NOT_EXECUTABLE,
                "crashpad_handler at " + shown +
                    " is not executable (was it copied without its mode?)");
  }
#endif
  const std::string revision = ReadRevisionStamp(handler);
  if (!revision.empty() && revision != FL_CRASHPAD_CRASHPAD_REVISION) {
    return Fail(error, FL_CRASHPAD_REVISION_MISMATCH,
                "crashpad_handler at " + shown + " was built from Crashpad " +
                    revision + ", but this library from " +
                    FL_CRASHPAD_CRASHPAD_REVISION +
                    "; the two must come from the same build");
  }
#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS)
  std::string why;
  if (!HandlerRuns(handler, &why)) {
    return Fail(error, FL_CRASHPAD_HANDLER_FAILED_TO_START,
                "crashpad_handler at " + shown + " cannot run: " + why);
  }
#endif
  return FL_CRASHPAD_OK;
}
#endif  // !BUILDFLAG(IS_ANDROID) && !BUILDFLAG(IS_IOS)

#if BUILDFLAG(IS_ANDROID)
// Where the system linker finds the two halves of the handler at the moment
// of a crash.
//
// Both ship inside the app as native libraries, which Android keeps inside
// the APK (`…/base.apk!/lib/x86_64/…`) unless the app asks for them to be
// extracted. The directory is read from this library's own path, as the
// dynamic linker reports it: whatever it loaded us from, it can load the
// trampoline from, and the trampoline can load us from again.
struct AndroidHandler {
  std::string trampoline;
  std::string library_directory;
  std::string library_name;
};

int32_t FindAndroidHandler(AndroidHandler* found, char** error) {
  Dl_info info = {};
  if (dladdr(reinterpret_cast<void*>(&fl_crashpad_abi_version), &info) == 0 ||
      info.dli_fname == nullptr) {
    return Fail(error, FL_CRASHPAD_HANDLER_MISSING,
                "could not find where libfl_crashpad_native.so was loaded from");
  }
  const std::string self(info.dli_fname);
  const size_t slash = self.rfind('/');
  if (slash == std::string::npos) {
    return Fail(error, FL_CRASHPAD_HANDLER_MISSING,
                "libfl_crashpad_native.so was loaded from " + self +
                    ", which has no directory");
  }
  found->library_directory = self.substr(0, slash);
  found->library_name = self.substr(slash + 1);
  found->trampoline =
      found->library_directory + "/libcrashpad_handler_trampoline.so";
  // Inside an APK there is no file to look at; the linker's own complaint
  // lands in logcat under the tag "crashpad" if the entry is missing.
  if (found->library_directory.find("!/") == std::string::npos &&
      access(found->trampoline.c_str(), F_OK) != 0) {
    return Fail(error, FL_CRASHPAD_HANDLER_MISSING,
                "the handler trampoline is not at " + found->trampoline +
                    " (was the app built with the package's build hook?)");
  }
  return FL_CRASHPAD_OK;
}

// This process's environment, with the library's directory as the linker's
// search path so that the trampoline's dlopen finds us by name.
std::vector<std::string> AndroidHandlerEnvironment(
    const std::string& library_directory) {
  static constexpr char kKey[] = "LD_LIBRARY_PATH=";
  std::vector<std::string> environment;
  std::string search_path = library_directory;
  for (char** entry = environ; entry != nullptr && *entry != nullptr;
       ++entry) {
    if (strncmp(*entry, kKey, sizeof(kKey) - 1) == 0) {
      const char* existing = *entry + sizeof(kKey) - 1;
      if (existing[0] != '\0') {
        search_path += std::string(":") + existing;
      }
    } else {
      environment.emplace_back(*entry);
    }
  }
  environment.push_back(kKey + search_path);
  return environment;
}
#endif

// ---------------------------------------------------------------------------
// Process state
//
// The client and the dictionary are created once and never destroyed:
// Crashpad cannot uninstall its handlers, and the dictionary is read by the
// handler at the moment of a crash, possibly while static destructors run.

// Leaked for the same reason, and because bionic's std::mutex has a
// destructor that would run while a crashing thread might hold it.
std::mutex& StartMutex() {
  static auto* mutex = new std::mutex();
  return *mutex;
}
std::atomic<bool> g_started{false};
CrashpadClient* g_client = nullptr;

std::mutex& AnnotationsMutex() {
  static auto* mutex = new std::mutex();
  return *mutex;
}

SimpleStringDictionary* Annotations() {
  static SimpleStringDictionary* dictionary = [] {
    auto* created = new SimpleStringDictionary();
    crashpad::CrashpadInfo::GetCrashpadInfo()->set_simple_annotations(created);
    return created;
  }();
  return dictionary;
}

std::unique_ptr<CrashReportDatabase> OpenDatabase(const char* path,
                                                  char** error,
                                                  int32_t* status) {
  if (!IsSet(path)) {
    *status = Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                   "the database path is empty");
    return nullptr;
  }
  auto database = CrashReportDatabase::Initialize(PathFromUtf8(path));
  if (!database) {
    *status = Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                   std::string("could not open the crash database at ") + path);
    return nullptr;
  }
  *status = FL_CRASHPAD_OK;
  return database;
}

bool ParseReportId(const char* id, UUID* uuid) {
  return IsSet(id) && uuid->InitializeFromString(std::string_view(id));
}

void AppendReports(std::string* out,
                   const std::vector<CrashReportDatabase::Report>& reports,
                   const char* state,
                   bool* first) {
  for (const auto& report : reports) {
    if (!*first) {
      out->push_back(',');
    }
    *first = false;
    out->append("{\"id\":");
    AppendJsonString(out, report.uuid.ToString());
    out->append(",\"state\":");
    AppendJsonString(out, state);
    out->append(",\"createdAt\":");
    out->append(std::to_string(static_cast<long long>(report.creation_time)));
    out->append(",\"uploaded\":");
    out->append(report.uploaded ? "true" : "false");
    out->append(",\"remoteId\":");
    AppendJsonString(out, report.id);
    out->append(",\"uploadAttempts\":");
    out->append(std::to_string(report.upload_attempts));
    out->append(",\"uploadExplicitlyRequested\":");
    out->append(report.upload_explicitly_requested ? "true" : "false");
    out->append(",\"path\":");
    AppendJsonString(out, Utf8FromPath(report.file_path));
    out->push_back('}');
  }
}

// Recursion the optimiser cannot turn into a loop: every frame keeps a live
// buffer, and the result depends on the frame below.
#if defined(_MSC_VER)
#define FL_CRASHPAD_NOINLINE __declspec(noinline)
#else
#define FL_CRASHPAD_NOINLINE __attribute__((noinline))
#endif

#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winfinite-recursion"
#elif defined(_MSC_VER)
#pragma warning(push)
#pragma warning(disable : 4717)  // Recursive on all control paths: the point.
#endif
FL_CRASHPAD_NOINLINE int Recurse(int depth) {
  volatile char frame[4096];
  frame[depth % sizeof(frame)] = static_cast<char>(depth);
  return Recurse(depth + 1) + frame[0];
}
#if defined(__clang__)
#pragma clang diagnostic pop
#elif defined(_MSC_VER)
#pragma warning(pop)
#endif

}  // namespace

// ---------------------------------------------------------------------------
// The ABI

extern "C" {

uint32_t fl_crashpad_abi_version(void) {
  return FL_CRASHPAD_ABI_VERSION;
}

const char* fl_crashpad_crashpad_revision(void) {
  return FL_CRASHPAD_CRASHPAD_REVISION;
}

int32_t fl_crashpad_start(const fl_crashpad_config* config, char** error) {
  if (config == nullptr ||
      config->struct_size < offsetof(fl_crashpad_config, wer_module_path)) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                "the configuration is missing or from an unknown ABI");
  }
#if BUILDFLAG(IS_ANDROID) || BUILDFLAG(IS_IOS)
  if (!IsSet(config->database_path)) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                "the database path is required");
  }
#else
  if (!IsSet(config->handler_path) || !IsSet(config->database_path)) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                "the handler path and the database path are required");
  }
#endif

  std::lock_guard<std::mutex> lock(StartMutex());
  if (g_started.load()) {
    return Fail(error, FL_CRASHPAD_ALREADY_STARTED,
                "Crashpad is already started in this process");
  }

#if BUILDFLAG(IS_ANDROID)
  if (android_get_device_api_level() < 29) {
    return Fail(error, FL_CRASHPAD_UNSUPPORTED,
                "Crashpad needs Android 10 (API 29) or later to start its "
                "handler from inside an APK; this is API " +
                    std::to_string(android_get_device_api_level()));
  }
  AndroidHandler android_handler;
  int32_t checked = FindAndroidHandler(&android_handler, error);
  if (checked != FL_CRASHPAD_OK) {
    return checked;
  }
#elif !BUILDFLAG(IS_IOS)
  const base::FilePath handler = PathFromUtf8(config->handler_path);
  int32_t checked = CheckHandler(handler, error);
  if (checked != FL_CRASHPAD_OK) {
    return checked;
  }
#endif

  const base::FilePath database = PathFromUtf8(config->database_path);
  // Consent lives in the database's settings, not on the command line, so it
  // is written before the handler reads it.
  {
    int32_t status = FL_CRASHPAD_OK;
    auto opened = OpenDatabase(config->database_path, error, &status);
    if (!opened) {
      return status;
    }
    const bool enabled =
        (config->flags & FL_CRASHPAD_FLAG_UPLOADS_ENABLED) != 0;
    if (!opened->GetSettings()->SetUploadsEnabled(enabled)) {
      return Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                  "could not record the upload setting in the database");
    }
  }

  std::map<std::string, std::string> annotations;
  for (size_t i = 0; i < config->annotation_count; ++i) {
    const fl_crashpad_pair& pair = config->annotations[i];
    if (!IsSet(pair.key) || pair.value == nullptr) {
      return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                  "an annotation has an empty key or a missing value");
    }
    annotations[pair.key] = pair.value;
  }

  std::vector<base::FilePath> attachments;
  for (size_t i = 0; i < config->attachment_count; ++i) {
    if (!IsSet(config->attachments[i])) {
      return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                  "an attachment path is empty");
    }
    attachments.push_back(PathFromUtf8(config->attachments[i]));
  }

  std::vector<std::string> arguments;
  if (config->flags & FL_CRASHPAD_FLAG_NO_RATE_LIMIT) {
    arguments.push_back("--no-rate-limit");
  }
  if (config->flags & FL_CRASHPAD_FLAG_NO_UPLOAD_GZIP) {
    arguments.push_back("--no-upload-gzip");
  }
  if (config->flags & FL_CRASHPAD_FLAG_NO_IDENTIFY_CLIENT_VIA_URL) {
    arguments.push_back("--no-identify-client-via-url");
  }
  if (config->flags & FL_CRASHPAD_FLAG_NO_PERIODIC_TASKS) {
    arguments.push_back("--no-periodic-tasks");
  }
  for (size_t i = 0; i < config->argument_count; ++i) {
    if (config->arguments[i] != nullptr) {
      arguments.push_back(config->arguments[i]);
    }
  }

  // Registered before the handler starts, so a crash during start-up already
  // carries whatever runtime annotations were set.
  {
    std::lock_guard<std::mutex> annotations_lock(AnnotationsMutex());
    Annotations();
  }

  const base::FilePath metrics = IsSet(config->metrics_path)
                                    ? PathFromUtf8(config->metrics_path)
                                    : base::FilePath();
  auto* client = new CrashpadClient();
#if BUILDFLAG(IS_ANDROID)
  // Launched at the crash rather than kept running: nothing idles in the
  // background, and nothing here uploads — with no URL the handler parks
  // every report, and the package sends it, sanitised, on a later launch.
  // Crashpad's own Android transport could not have: it speaks plain http
  // only, BoringSSL being wired up solely inside Chromium.
  //
  // The linker entry point takes no attachments, so they travel as the
  // arguments the handler would have been given for them.
  for (const auto& attachment : attachments) {
    arguments.push_back("--attachment=" + attachment.value());
  }
  const std::vector<std::string> environment =
      AndroidHandlerEnvironment(android_handler.library_directory);
  const bool started = client->StartHandlerWithLinkerAtCrash(
      android_handler.trampoline, android_handler.library_name,
      /*is_64_bit=*/sizeof(void*) == 8, &environment, database, metrics,
      /*url=*/std::string(), annotations, arguments);
  const std::string started_what = "the handler trampoline at " +
                                   android_handler.trampoline;
#elif BUILDFLAG(IS_IOS)
  // In process: Mach exceptions, signals and uncaught NSExceptions are
  // written as intermediate dumps into the database, and become reports
  // when fl_crashpad_process_pending_dumps runs. No URL, so no upload
  // thread: as on Android, the package uploads after sanitising.
  (void)metrics;
  const bool started = CrashpadClient::StartCrashpadInProcessHandler(
      database, /*url=*/std::string(), annotations,
      CrashpadClient::ProcessPendingReportsObservationCallback());
  const std::string started_what = "the in-process handler";
#else
  const bool started = client->StartHandler(
      handler, database, metrics,
      IsSet(config->url) ? std::string(config->url) : std::string(),
      annotations, arguments,
      /*restartable=*/true,
      // Synchronous everywhere: a start that returns success has a handler,
      // and a crash in the first milliseconds after it is still reported.
      /*asynchronous_start=*/false, attachments);
  const std::string started_what =
      "the handler at " + std::string(config->handler_path);
#endif
  if (!started) {
    delete client;
    return Fail(error, FL_CRASHPAD_HANDLER_FAILED_TO_START,
                "Crashpad could not start " + started_what +
                    " (Crashpad's own reason is in its log)");
  }

#if BUILDFLAG(IS_WIN)
  if (IsSet(config->wer_module_path)) {
    // Registration only stashes the path; whether WER uses it depends on the
    // registry entry the application installs. Not a reason to fail start.
    client->RegisterWerModule(base::UTF8ToWide(config->wer_module_path));
  }
#endif

  g_client = client;
  g_started.store(true);
  return FL_CRASHPAD_OK;
}

bool fl_crashpad_is_started(void) {
  return g_started.load();
}

int32_t fl_crashpad_annotation_set(const char* key, const char* value) {
  if (!IsSet(key) || value == nullptr) {
    return FL_CRASHPAD_INVALID_ARGUMENT;
  }
  if (strlen(key) > FL_CRASHPAD_ANNOTATION_KEY_MAX ||
      strlen(value) > FL_CRASHPAD_ANNOTATION_VALUE_MAX) {
    return FL_CRASHPAD_LIMIT_EXCEEDED;
  }
  std::lock_guard<std::mutex> lock(AnnotationsMutex());
  SimpleStringDictionary* dictionary = Annotations();
  if (dictionary->GetValueForKey(key) == nullptr &&
      dictionary->GetCount() >= FL_CRASHPAD_ANNOTATION_ENTRIES_MAX) {
    return FL_CRASHPAD_LIMIT_EXCEEDED;
  }
  dictionary->SetKeyValue(key, value);
  return FL_CRASHPAD_OK;
}

int32_t fl_crashpad_annotation_remove(const char* key) {
  if (!IsSet(key)) {
    return FL_CRASHPAD_INVALID_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(AnnotationsMutex());
  Annotations()->RemoveKey(key);
  return FL_CRASHPAD_OK;
}

void fl_crashpad_annotation_clear(void) {
  std::lock_guard<std::mutex> lock(AnnotationsMutex());
  SimpleStringDictionary* dictionary = Annotations();
  std::vector<std::string> keys;
  SimpleStringDictionary::Iterator it(*dictionary);
  while (const SimpleStringDictionary::Entry* entry = it.Next()) {
    keys.emplace_back(entry->key);
  }
  for (const auto& key : keys) {
    dictionary->RemoveKey(key.c_str());
  }
}

bool fl_crashpad_initialize_signal_stack_for_thread(void) {
#if BUILDFLAG(IS_LINUX) || BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(IS_ANDROID)
  return CrashpadClient::InitializeSignalStackForThread();
#else
  return true;
#endif
}

void fl_crashpad_dump_without_crash(void) {
  CRASHPAD_SIMULATE_CRASH();
}

void fl_crashpad_crash_for_testing(int32_t kind) {
  switch (kind) {
    case FL_CRASHPAD_CRASH_SEGFAULT: {
      volatile int* null = nullptr;
      *null = 0;
      break;
    }
    case FL_CRASHPAD_CRASH_ABORT:
      abort();
    case FL_CRASHPAD_CRASH_STACK_OVERFLOW_ON_THREAD: {
      std::thread thread([] {
        fl_crashpad_initialize_signal_stack_for_thread();
        Recurse(0);
      });
      thread.join();
      break;
    }
  }
  // Only reached for an unknown kind, or if a crash was somehow survived.
  abort();
}

int32_t fl_crashpad_database_get_uploads_enabled(const char* database_path,
                                                 bool* enabled,
                                                 char** error) {
  if (enabled == nullptr) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT, "enabled is null");
  }
  int32_t status = FL_CRASHPAD_OK;
  auto database = OpenDatabase(database_path, error, &status);
  if (!database) {
    return status;
  }
  if (!database->GetSettings()->GetUploadsEnabled(enabled)) {
    return Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                "could not read the upload setting");
  }
  return FL_CRASHPAD_OK;
}

int32_t fl_crashpad_database_set_uploads_enabled(const char* database_path,
                                                 bool enabled,
                                                 char** error) {
  int32_t status = FL_CRASHPAD_OK;
  auto database = OpenDatabase(database_path, error, &status);
  if (!database) {
    return status;
  }
  if (!database->GetSettings()->SetUploadsEnabled(enabled)) {
    return Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                "could not record the upload setting");
  }
  return FL_CRASHPAD_OK;
}

int32_t fl_crashpad_database_reports(const char* database_path,
                                     char** json,
                                     char** error) {
  if (json == nullptr) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT, "json is null");
  }
  int32_t status = FL_CRASHPAD_OK;
  auto database = OpenDatabase(database_path, error, &status);
  if (!database) {
    return status;
  }
  std::vector<CrashReportDatabase::Report> pending;
  std::vector<CrashReportDatabase::Report> completed;
  if (database->GetPendingReports(&pending) != CrashReportDatabase::kNoError ||
      database->GetCompletedReports(&completed) !=
          CrashReportDatabase::kNoError) {
    return Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                "could not list the reports in the database");
  }
  std::string out = "[";
  bool first = true;
  AppendReports(&out, pending, "pending", &first);
  AppendReports(&out, completed, "completed", &first);
  out.push_back(']');
  *json = Duplicate(out);
  return FL_CRASHPAD_OK;
}

int32_t fl_crashpad_database_request_upload(const char* database_path,
                                            const char* report_id,
                                            char** error) {
  UUID uuid;
  if (!ParseReportId(report_id, &uuid)) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                "not a report id: " + std::string(report_id ? report_id : ""));
  }
  int32_t status = FL_CRASHPAD_OK;
  auto database = OpenDatabase(database_path, error, &status);
  if (!database) {
    return status;
  }
  switch (database->RequestUpload(uuid)) {
    case CrashReportDatabase::kNoError:
      return FL_CRASHPAD_OK;
    case CrashReportDatabase::kReportNotFound:
      return Fail(error, FL_CRASHPAD_REPORT_NOT_FOUND,
                  "no pending report " + std::string(report_id));
    default:
      return Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                  "could not request an upload of " + std::string(report_id));
  }
}

int32_t fl_crashpad_database_delete_report(const char* database_path,
                                           const char* report_id,
                                           char** error) {
  UUID uuid;
  if (!ParseReportId(report_id, &uuid)) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                "not a report id: " + std::string(report_id ? report_id : ""));
  }
  int32_t status = FL_CRASHPAD_OK;
  auto database = OpenDatabase(database_path, error, &status);
  if (!database) {
    return status;
  }
  switch (database->DeleteReport(uuid)) {
    case CrashReportDatabase::kNoError:
      return FL_CRASHPAD_OK;
    case CrashReportDatabase::kReportNotFound:
      return Fail(error, FL_CRASHPAD_REPORT_NOT_FOUND,
                  "no report " + std::string(report_id));
    default:
      return Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                  "could not delete " + std::string(report_id));
  }
}

int32_t fl_crashpad_report_upload_fields(const char* minidump_path,
                                         char** json,
                                         char** error) {
  if (json == nullptr || !IsSet(minidump_path)) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                "a minidump path and somewhere to write are required");
  }
  crashpad::FileReader reader;
  if (!reader.Open(PathFromUtf8(minidump_path))) {
    return Fail(error, FL_CRASHPAD_REPORT_NOT_FOUND,
                std::string("could not open ") + minidump_path);
  }
  // As CrashReportUploadThread::UploadReport does it: a dump that does not
  // parse is still sent, just with no fields.
  std::map<std::string, std::string> fields;
  crashpad::ProcessSnapshotMinidump snapshot;
  if (snapshot.Initialize(&reader)) {
    fields = crashpad::BreakpadHTTPFormParametersFromMinidump(&snapshot);
  }
  std::string out = "{";
  bool first = true;
  for (const auto& field : fields) {
    if (!first) {
      out.push_back(',');
    }
    first = false;
    AppendJsonString(&out, field.first);
    out.push_back(':');
    AppendJsonString(&out, field.second);
  }
  out.push_back('}');
  *json = Duplicate(out);
  return FL_CRASHPAD_OK;
}

int32_t fl_crashpad_database_record_upload(const char* database_path,
                                           const char* report_id,
                                           int32_t outcome,
                                           const char* response,
                                           char** error) {
  // Crashpad's own uploader gives up after this many (on iOS, the one
  // platform where it retries at all).
  static constexpr int kAttempts = 5;
  UUID uuid;
  if (!ParseReportId(report_id, &uuid)) {
    return Fail(error, FL_CRASHPAD_INVALID_ARGUMENT,
                "not a report id: " + std::string(report_id ? report_id : ""));
  }
  int32_t status = FL_CRASHPAD_OK;
  auto database = OpenDatabase(database_path, error, &status);
  if (!database) {
    return status;
  }
  if (outcome == FL_CRASHPAD_UPLOAD_SKIPPED) {
    if (database->SkipReportUpload(
            uuid, crashpad::Metrics::CrashSkippedReason::kUploadsDisabled) !=
        CrashReportDatabase::kNoError) {
      return Fail(error, FL_CRASHPAD_REPORT_NOT_PENDING,
                  "no pending report " + std::string(report_id));
    }
    return FL_CRASHPAD_OK;
  }

  std::unique_ptr<const CrashReportDatabase::UploadReport> report;
  switch (database->GetReportForUploading(uuid, &report,
                                          /*report_metrics=*/false)) {
    case CrashReportDatabase::kNoError:
      break;
    case CrashReportDatabase::kReportNotFound:
      return Fail(error, FL_CRASHPAD_REPORT_NOT_PENDING,
                  "no pending report " + std::string(report_id));
    default:
      return Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                  "could not open " + std::string(report_id) +
                      " for recording its upload");
  }
  if (outcome == FL_CRASHPAD_UPLOAD_SENT) {
    if (database->RecordUploadComplete(std::move(report),
                                       response ? response : "") !=
        CrashReportDatabase::kNoError) {
      return Fail(error, FL_CRASHPAD_DATABASE_ERROR,
                  "could not record the upload of " + std::string(report_id));
    }
    return FL_CRASHPAD_OK;
  }
  // Released without completing, the report records one failed attempt and
  // stays pending.
  const int attempts = report->upload_attempts + 1;
  report.reset();
  if (attempts >= kAttempts) {
    database->SkipReportUpload(
        uuid, crashpad::Metrics::CrashSkippedReason::kUploadFailed);
  }
  return FL_CRASHPAD_OK;
}

void fl_crashpad_process_pending_dumps(void) {
#if BUILDFLAG(IS_IOS)
  if (g_started.load()) {
    CrashpadClient::ProcessIntermediateDumps();
  }
#endif
}

void fl_crashpad_free(void* pointer) {
  free(pointer);
}

}  // extern "C"
