/*
 * fl_crashpad — a C ABI over Google Crashpad's client.
 *
 * This header is the whole contract between the native library and anything
 * that loads it: the package's Dart bindings, and any other language in the
 * same process that wants to add annotations or give its threads a signal
 * stack (a Rust engine loaded into a Flutter app, say). It is plain C on
 * purpose, so that none of those callers needs to know Crashpad is C++.
 *
 * Conventions:
 *   - Every string is UTF-8 and NUL-terminated, on every platform. The
 *     library converts to UTF-16 itself on Windows.
 *   - A function that can fail returns an `fl_crashpad_status`. On failure it
 *     may also set `*error` to a message allocated by this library, which the
 *     caller releases with `fl_crashpad_free`. Pass NULL to ignore the message.
 *   - There is no thread-local "last error": the message comes back from the
 *     call that failed, or not at all.
 *   - Nothing here can be undone. Crashpad installs process-wide handlers that
 *     it has no way to uninstall, so there is a start and no stop.
 */
#ifndef FL_CRASHPAD_H_
#define FL_CRASHPAD_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(FL_CRASHPAD_IMPLEMENTATION)
#define FL_CRASHPAD_EXPORT __declspec(dllexport)
#else
#define FL_CRASHPAD_EXPORT __declspec(dllimport)
#endif
#else
#define FL_CRASHPAD_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped on any change a caller compiled against an older header would get
 * wrong. The Dart bindings refuse a library whose version they do not know. */
#define FL_CRASHPAD_ABI_VERSION 2

typedef enum fl_crashpad_status {
  FL_CRASHPAD_OK = 0,
  FL_CRASHPAD_INVALID_ARGUMENT = 1,
  FL_CRASHPAD_ALREADY_STARTED = 2,
  FL_CRASHPAD_HANDLER_MISSING = 3,
  FL_CRASHPAD_HANDLER_NOT_EXECUTABLE = 4,
  FL_CRASHPAD_HANDLER_FAILED_TO_START = 5,
  FL_CRASHPAD_REVISION_MISMATCH = 6,
  FL_CRASHPAD_DATABASE_ERROR = 7,
  FL_CRASHPAD_REPORT_NOT_FOUND = 8,
  /* An annotation over the size limits below, or one entry too many. */
  FL_CRASHPAD_LIMIT_EXCEEDED = 9,
  /* The OS cannot run Crashpad here: Android before 10 (API 29), whose
   * system linker cannot start the handler out of an APK. */
  FL_CRASHPAD_UNSUPPORTED = 10,
  /* The report is not waiting to be uploaded. */
  FL_CRASHPAD_REPORT_NOT_PENDING = 11,
} fl_crashpad_status;

/* Runtime annotation limits, in bytes of UTF-8 excluding the terminator.
 * They are Crashpad's SimpleStringDictionary's, which is what a crash reads
 * without allocating. Annotations passed to start() have no such limit: they
 * travel on the handler's command line instead. */
#define FL_CRASHPAD_ANNOTATION_KEY_MAX 255
#define FL_CRASHPAD_ANNOTATION_VALUE_MAX 255
#define FL_CRASHPAD_ANNOTATION_ENTRIES_MAX 64

/* fl_crashpad_config.flags */
#define FL_CRASHPAD_FLAG_UPLOADS_ENABLED (1u << 0)
#define FL_CRASHPAD_FLAG_NO_RATE_LIMIT (1u << 1)
#define FL_CRASHPAD_FLAG_NO_UPLOAD_GZIP (1u << 2)
#define FL_CRASHPAD_FLAG_NO_IDENTIFY_CLIENT_VIA_URL (1u << 3)
#define FL_CRASHPAD_FLAG_NO_PERIODIC_TASKS (1u << 4)

typedef struct fl_crashpad_pair {
  const char* key;
  const char* value;
} fl_crashpad_pair;

typedef struct fl_crashpad_config {
  /* sizeof(fl_crashpad_config) as the caller compiled it, so a field can be
   * appended in a later ABI without breaking an older caller. */
  uint32_t struct_size;
  uint32_t flags;
  /* Required on desktop: the crashpad_handler executable. Ignored on Android,
   * where the handler is this library, started through the trampoline beside
   * it, and on iOS, where crashes are handled inside the process. */
  const char* handler_path;
  /* Required. Created if it does not exist. */
  const char* database_path;
  /* Optional (NULL): where the handler keeps its metrics. */
  const char* metrics_path;
  /* Optional (NULL): the endpoint minidumps are POSTed to. With no URL,
   * reports stay in the database. Ignored on Android and iOS, whose reports
   * the caller uploads itself (see fl_crashpad_report_upload_fields). */
  const char* url;
  /* Process annotations, attached to every report. */
  const fl_crashpad_pair* annotations;
  size_t annotation_count;
  /* Files read at the moment of a crash and attached to its report. Not
   * supported on iOS. */
  const char* const* attachments;
  size_t attachment_count;
  /* Extra handler command-line arguments, passed through verbatim. Ignored
   * on iOS, which has no handler process. */
  const char* const* arguments;
  size_t argument_count;
  /* Windows only, optional (NULL): crashpad_wer.dll, registered so that
   * fast-fail crashes — which skip the unhandled exception filter — are
   * reported too. Ignored elsewhere. */
  const char* wer_module_path;
} fl_crashpad_config;

/* The version this library was built with; compare with the header's. */
FL_CRASHPAD_EXPORT uint32_t fl_crashpad_abi_version(void);

/* The Crashpad revision this library was built from, a static string. */
FL_CRASHPAD_EXPORT const char* fl_crashpad_crashpad_revision(void);

/* Starts the handler and installs this process's crash handlers. Once per
 * process; a second call returns FL_CRASHPAD_ALREADY_STARTED.
 *
 * On desktop the handler is checked first: it must exist, be executable, and
 * — where a crashpad_handler.rev sits beside it — come from the same Crashpad
 * revision as this library. On Linux it is also run once with --version,
 * because Crashpad launches it with a double fork and cannot tell whether the
 * exec succeeded; a handler that cannot run would otherwise mean every later
 * crash is silently lost.
 *
 * On Android nothing runs until a crash: the signal handler then starts
 * /system/bin/linker64 on the trampoline beside this library, which loads
 * this library again as the handler. Android 10 or later.
 *
 * On iOS a crash is written as an intermediate dump inside the process, and
 * becomes a report only when fl_crashpad_process_pending_dumps runs, on a
 * later launch. */
FL_CRASHPAD_EXPORT int32_t fl_crashpad_start(const fl_crashpad_config* config,
                                             char** error);

FL_CRASHPAD_EXPORT bool fl_crashpad_is_started(void);

/* Runtime annotations: read at the moment of a crash, changeable at any time,
 * and usable before start(). Setting an existing key replaces its value. */
FL_CRASHPAD_EXPORT int32_t fl_crashpad_annotation_set(const char* key,
                                                      const char* value);
FL_CRASHPAD_EXPORT int32_t fl_crashpad_annotation_remove(const char* key);
FL_CRASHPAD_EXPORT void fl_crashpad_annotation_clear(void);

/* Linux and Android: gives the calling thread an alternate signal stack, so a stack
 * overflow on it is reported rather than killing the process silently.
 * Crashpad does this for the thread that calls start(); every other native
 * thread that might overflow should call this once, early. Harmless to call
 * twice. Returns true elsewhere, where there is nothing to do. */
FL_CRASHPAD_EXPORT bool fl_crashpad_initialize_signal_stack_for_thread(void);

/* Writes a report of the current state of the process and carries on. */
FL_CRASHPAD_EXPORT void fl_crashpad_dump_without_crash(void);

/* Crashes the process on purpose, for tests and for trying a setup out. */
typedef enum fl_crashpad_crash_kind {
  FL_CRASHPAD_CRASH_SEGFAULT = 0,
  FL_CRASHPAD_CRASH_ABORT = 1,
  /* Unbounded recursion on a new native thread. */
  FL_CRASHPAD_CRASH_STACK_OVERFLOW_ON_THREAD = 2,
} fl_crashpad_crash_kind;
FL_CRASHPAD_EXPORT void fl_crashpad_crash_for_testing(int32_t kind);

/* The report database, addressed by path. Usable before start(), which is
 * how an app records consent before the handler ever runs. */
FL_CRASHPAD_EXPORT int32_t fl_crashpad_database_get_uploads_enabled(
    const char* database_path,
    bool* enabled,
    char** error);
FL_CRASHPAD_EXPORT int32_t fl_crashpad_database_set_uploads_enabled(
    const char* database_path,
    bool enabled,
    char** error);

/* Every pending and completed report, as a JSON array written to *json:
 *   [{"id": "<uuid>", "state": "pending" | "completed",
 *     "createdAt": <unix seconds>, "uploaded": bool, "remoteId": "<id>",
 *     "uploadAttempts": n, "uploadExplicitlyRequested": bool,
 *     "path": "<minidump>"}]
 * Release it with fl_crashpad_free. */
FL_CRASHPAD_EXPORT int32_t fl_crashpad_database_reports(
    const char* database_path,
    char** json,
    char** error);
FL_CRASHPAD_EXPORT int32_t fl_crashpad_database_request_upload(
    const char* database_path,
    const char* report_id,
    char** error);
FL_CRASHPAD_EXPORT int32_t fl_crashpad_database_delete_report(
    const char* database_path,
    const char* report_id,
    char** error);

/* The form fields Crashpad's own uploader would send with a minidump, read
 * out of it the same way (BreakpadHTTPFormParametersFromMinidump), as a JSON
 * object of strings written to *json — for a caller that uploads reports
 * itself, as the Dart package does on Android and iOS. A minidump that cannot
 * be parsed gives an empty object, as it gives Crashpad's uploader no fields.
 * Release it with fl_crashpad_free. */
FL_CRASHPAD_EXPORT int32_t fl_crashpad_report_upload_fields(
    const char* minidump_path,
    char** json,
    char** error);

/* What came of an upload the caller made itself. */
typedef enum fl_crashpad_upload_outcome {
  /* Accepted; the response body is recorded as the report's remote id. */
  FL_CRASHPAD_UPLOAD_SENT = 0,
  /* Not accepted. The report stays pending for another attempt, up to five,
   * after which it is given up on, as Crashpad's own uploader does. */
  FL_CRASHPAD_UPLOAD_FAILED = 1,
  /* Not to be sent: moved to completed without an upload. */
  FL_CRASHPAD_UPLOAD_SKIPPED = 2,
} fl_crashpad_upload_outcome;

/* Records the outcome of an upload of a pending report, the way Crashpad's
 * upload thread would have. */
FL_CRASHPAD_EXPORT int32_t fl_crashpad_database_record_upload(
    const char* database_path,
    const char* report_id,
    int32_t outcome,
    const char* response,
    char** error);

/* iOS: turns the intermediate dumps a crash left into reports in the
 * database. Blocks while it works, so it belongs off the UI thread; does
 * nothing before start() and on every other platform. */
FL_CRASHPAD_EXPORT void fl_crashpad_process_pending_dumps(void);

/* Releases anything this library allocated and handed back. */
FL_CRASHPAD_EXPORT void fl_crashpad_free(void* pointer);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // FL_CRASHPAD_H_
