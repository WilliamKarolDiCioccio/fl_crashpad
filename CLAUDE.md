# Working on fl_crashpad

Native crash reporting for Flutter apps over Google Crashpad — desktop,
Android and iOS. A standalone package, meant for pub.dev and to be consumed by `ripple_effect` as
a git submodule; it knows nothing about any app, any logger or any backend.

## Environment

**`flutter` and `dart` are not on PATH.** The toolchain is pinned in `.fvmrc`
to 3.41.9 and reached through FVM:

```sh
export PATH="$HOME/fvm/versions/3.41.9/bin:$PATH"
```

**The tests need the native half.** Before anything else, once per machine and
again after touching `native/` or the lock:

```sh
dart run tool/build_native.dart --install
```

It wants git, python3, clang 17 or newer (the first to accept
`-std=c++23`, which mini_chromium builds with), and libcurl's and zlib's headers
(`libcurl4-openssl-dev zlib1g-dev`). Without root, fetch the curl headers with
`apt-get download libcurl4-openssl-dev`, unpack with `dpkg-deb -x`, and pass
`--extra-cflags -I<root>/usr/include/x86_64-linux-gnu --extra-ldflags
-L<dir with a libcurl.so symlink to /lib/x86_64-linux-gnu/libcurl.so.4>`.
The handler only needs them to compile: it `dlopen`s libcurl at run time.

**Android** builds from here with the SDK's NDK (`~/Android/Sdk/ndk/*`, the
newest wins; `--ndk` or `ANDROID_NDK_HOME` to choose):
`dart run tool/build_native.dart --target android-x64 --install`, and
`android-arm64` likewise. **iOS** builds only on a Mac with Xcode.

**A Flutter with Android or iOS disabled globally**
(`flutter config --no-enable-android --no-enable-ios`, as on a machine set up
for desktop work) makes `flutter create --platforms=android` write *nothing*
— it says "Wrote 0 files" — and `flutter build apk` refuse. Enable them for
mobile work and put the setting back afterwards.

**After rebuilding, clear the hook caches** or the tests load the previous
library: the hooks runner keeps its last output while the lock is unchanged.

```sh
find . test/crasher -maxdepth 4 -path '*/.dart_tool/*' -type d \
  \( -name hooks_runner -o -name native_assets \) -exec rm -rf {} +
```

## Verifying a change

```sh
dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos
dart test                                     # includes real crashes, in child processes
cd example && flutter analyze && flutter test && flutter build linux
build/linux/x64/release/bundle/fl_crashpad_example --database=/tmp/db --crash=segfault
```

Android, on an emulator or device (Android 10+) once the build for its ABI is
in the cache — it was first proved on an x86_64 API 37 image with 16 KB pages:

```sh
~/Android/Sdk/emulator/emulator -avd <avd> -no-snapshot-save &
dart run tool/android_e2e.dart
```

`native.yml` (dispatch-only, see *Releasing the native half*) builds every
target from source and runs the same `dart test` on each desktop one, the
example on Linux, Windows x64, macOS and iOS, and the Android check on an
emulator. Spend a run on it for any change to `native/`, the lock, the build
tooling or the platform files.

## House style

The same as `fl_nodes_v2`'s, which is where it is written out at length.

Tests: local factory closures at the top of `main()`, `addTearDown` for what a
test creates, `reason:` on anything non-obvious, no mocks, helpers declared
before first use. **A test has to be able to fail**: break the line it guards
and watch it go red before trusting it (done for the thread stack overflow and
the minidump reader's offsets). British spelling in prose ("normalises",
"colour").

Comments earn their place by saying *why*, especially where the obvious
implementation is wrong. Doc comments on public API; a `///` on a field that
just restates its name is noise.

The CHANGELOG is the **consumer's** summary, by version: what an app can do
now, a line or two per change, the symbol in backticks with its default in
parentheses. Not why, not how, and never the test that pins it — the reasons
live in this file. Work in flight goes under `## Unreleased`.

`lints`, not `flutter_lints`, and a `no-flutter` hook as in `dart_read_time`:
`lib/` reaches no Flutter, which is what keeps `dart test` and the build hook
working.

## The decisions, and why

**Why not crashpad-rs and flutter_rust_bridge**, which was the starting idea
(checked 2026-09-28):
- **crashpad-rs is abandoned.**
  - Its last release was 0.2.7 on 2025-08-28; it has 2 stars and about 50
    unmerged weekly bot PRs.
  - It pins Crashpad `811b0429`.
  - Its C++ wrapper sets annotations only at start. It has no runtime
    annotations, no attachments and no database or consent API.
  - Its prebuilts lack macOS x64 and arm64 Linux/Windows, whatever its
    README says.
  - Its handler bundler copies into cargo's `target/`, which is no use to a
    Flutter bundle.
- **FRB would make every consumer install rustup** and pin our exact
  `flutter_rust_bridge` version.
- The user chose instead: a C++ shim over upstream Crashpad, a C ABI
  (`native/include/fl_crashpad.h`), and `dart:ffi` `@Native` through a build
  hook.
- An in-process Rust engine is covered all the same. Crashpad's handlers are
  process-wide.

**A hook cannot ship an executable**, so the handler travels through
package-owned platform files and the library through the hook (see
`handler_location.dart` for where each lands). This was checked in
flutter_tools 3.41.9:
- **macOS:** every code asset goes through `otool -D … .single` and
  `install_name_tool -id`, which throws for an `MH_EXECUTE`.
- **Linux:** the runner's `install(DIRECTORY native_assets)` makes files 0644.
- **Windows:** the only platform where it would have worked.

**One artifact cache, three readers.** The layout and resolution order are
written three times, and all three change together:
- `lib/src/build/native_artifacts.dart` (the hook and `prefetch`). This one is
  the reference.
- `cmake/fetch_artifact.cmake` (Linux and Windows).
- `macos/Scripts/embed_handler.sh` (the pod).

**How the three coordinate:**
- **Location:** the cache root derives from `HOME`/`USERPROFILE` only, because
  hooks_runner filters every other variable. For the same reason the hook's
  override is a user-define, while CMake and the pod read an env var.
- **Downloads:** each writes into a private staging directory beside the
  destination, `rename`s it into place, and stamps it `.complete`. Parallel
  builds race, and a loser keeps the winner's copy.
- **The lock:** CMake and the pod cannot parse JSON, so `tool/update_lock.dart`
  writes `.cmake` and `.txt` copies of it. `artifacts_test.dart` fails if the
  three disagree.
- **Ordering:** CMake fetches at *build* time in an `ALL` custom target, and
  the pod fetches in its own script phase. Neither waits for the hook, because
  nothing orders them.

**The GN overlay.** `tool/build_native.dart` copies `native/` into the
Crashpad checkout as `third_party/fl_crashpad/` and runs `gn gen --root=…
--dotfile=native/fl_crashpad.gn`, whose only addition to Crashpad's `.gn` is
`root = "//third_party/fl_crashpad:root"`. Upstream is never patched.
- **The toolchain is Crashpad's own.** The library is compiled with exactly
  the toolchain, flags and runtime library that compile the handler.
- **Build `:root` by name.** GN still loads Crashpad's test targets, so a bare
  `ninja` goes looking for googletest.
- **The library is a `crashpad_loadable_module`.** mini_chromium has no
  `solink` tool, only `solink_module`, which names every POSIX module `.so`.
  So `output_extension` is set to `dylib` on macOS.

**Only `fl_crashpad_*` is exported.** The mechanism differs by platform:
- **Linux:** a version script plus `--exclude-libs,ALL -Bsymbolic`, with
  libstdc++ linked statically.
- **macOS:** an exported-symbols list.
- **Windows:** a `.def` file.

The three lists in `native/exports/` change together. Annotations still reach
the handler, because it finds each module's `CrashpadInfo` through an ELF
note, a Mach-O section or a PE section (`CPADinfo`), not through a symbol.

**Windows uses `/MD`.** mini_chromium passes no CRT flag, so MSVC's default
static runtime would apply. Crashpad catches `abort()` through the CRT's
`signal(SIGABRT)`, and with a private static CRT it would see no abort but its
own.

**Windows builds with Visual Studio's cl.exe only**
(`mini_chromium_is_clang=false`), the compiler Flutter's own Windows builds
use. clang-cl was dropped: mini_chromium writes `clang_path` into its ninja
commands unquoted and relative to the build directory, so the runner's
`C:/Program Files/LLVM` on a build on `D:` became
`../../../../C:/Program`. Any LLVM in its default place breaks the same way.

**Windows on Arm CI** has no Flutter archive, so it clones the release tag and
precaches; that Flutter's Dart is the x64 fallback, which cannot load an arm64
library, so the tests run on the native arm64 Dart SDK of the same release.
The example is built on x64 only, since the x64 tool builds an x64 app.
Linux on Arm has no archive either and clones the same way (`flutter-git` in
the matrix); its Dart is native.

**macOS deployment target 12.0**, not Flutter's 10.15: at the pinned revision
`util/mac/mac_util.cc` uses `kIOMainPortDefault` unguarded, which IOKit marks
12.0, so `-Werror` rejects any lower target. CI selects the newest stable
Xcode, because macos-14's default (15.4) has a clang that rejects
`-std=c++23`. iOS is 13.0.

**The macOS framework is signed ad hoc, inside out**, handler first, by
`embed_handler.sh`, so a release built with no signing identity still signs
over it; a Developer ID build re-signs both. Nothing but code may sit in
`Helpers/`, which is why macOS has no `crashpad_handler.rev`.

**Linux builds against the host.** The glibc floor is the build machine's, so
CI uses ubuntu-22.04 (2.35), with clang 18 from apt.llvm.org because the
image's own is 14. mini_chromium runs whichever `clang` is first on `PATH`.
- **The sysroot doesn't work.** Crashpad's own 2021 sysroot has glibc 2.31,
  but its libstdc++ (gcc 10) has no `std::bit_cast`, which current
  mini_chromium needs.
- **Upstream gets away with it** only because its CI also pulls the Fuchsia
  clang and that clang's libc++.
- `--sysroot` remains for anybody with a suitable one.

**The handler is checked before `start` trusts it**:
- it exists, and is executable;
- its `crashpad_handler.rev` matches `fl_crashpad_crashpad_revision()`, where
  there is one — not on macOS (see above), where the handler and the library
  are two files of one universal artifact and it is taken on trust;
- on Linux, `--version` runs within five seconds.

Crashpad's Linux `StartHandler` double-forks and cannot tell a failed exec
from a running handler.

**Non-main native threads on Linux need `fl_crashpad_initialize_signal_stack_for_thread()`**
to report a stack overflow. This is proved by breaking it: without the call,
`crash_test.dart`'s `stackOverflowOnThread` goes red. The shim is loaded too
late for Crashpad's `pthread_create` wrapper to help.

**Windows fast-fail** goes through `crashpad_wer.dll`, which WER loads only
if the process registered it (`RegisterWerModule`, in the shim) **and** it is
listed under HKCU's `RuntimeExceptionHelperModules`. `start` writes that value
itself (`lib/src/wer_registration.dart`, Dart FFI to advapi32, so no native
change and no ABI bump), every start, before the handler launches:
- **The package, not the installer**, because HKCU needs no elevation and an
  installer step misses a zip, a portable copy, `flutter run` and a moved
  app. It was the installer's until 2026-09-30, and ripple_effect had not
  written it: fast-fail crashes went unreported there.
- **Written, not checked**: one idempotent write, never stale after a move.
- **Never removed** — the package has no uninstall hook. A value naming a DLL
  that is gone is inert. An installer may still add it with
  `uninsdeletevalue` to tidy up, and the README shows how.
- **A refusal is swallowed.** A locked-down profile costs the fast-fail
  crashes, not `start`.
- **The error mode is the other half, and it was found the hard way.** With
  the value written, the Windows runners still produced no report. The
  process's error mode was `0x8003`: the Dart runtime sets
  `SEM_NOGPFAULTERRORBOX`, which means Windows *does not invoke WER at all*,
  and a child inherits it. With it cleared in the crasher, the report
  appeared. So `start` clears it too (`letWerSeeFastFails`). What the bit was
  there for was no crash dialog, so when it was set, `start` also calls
  `WerSetFlags(WER_FAULT_REPORTING_NO_UI)`, and nobody sees a difference.
  A crash Crashpad's filter catches never reaches WER, so this changes
  nothing for them.
- **Proved by `crash_test.dart`** on the Windows runners: the crasher's
  `fastfail` kind calls `RaiseFailFastException` from kernel32 directly, and
  the test expects the HKCU value and a sanitised report. Everywhere else
  it is skipped.

**Errors come back from the call that failed** — a status code, plus a
malloc'd message freed with `fl_crashpad_free`. There is no thread-local
`last_error`.

**Static Dart API**, because there is one Crashpad per process and no `stop`.
`start` is synchronous on purpose: a start that returned is a covered process.

## Mobile: the decisions, and why

Added 2026-09-29, from reading Crashpad's Android and iOS paths at the pinned
revision before planning. The user approved the one real decision — **mobile
reports are uploaded by Dart** — with the plan.

**Neither mobile platform has a handler executable, so both travel entirely
as code assets** — no `android/`, no Gradle, no Kotlin, no pod. flutter_tools
3.41.9 copies an Android code asset into `jniLibs/lib/<abi>/` under its own
file name and does nothing else to it
(`isolated/native_assets/android/native_assets.dart`). iOS code assets become
frameworks, which is fine for a dylib.

**Android: the library is the handler.**
- Upstream's answer to W^X and to libraries that stay inside the APK is
  `StartHandlerWithLinkerAtCrash` (Android 10+). At a crash,
  `/system/bin/linker64` runs `libcrashpad_handler_trampoline.so` (a PIE
  named `.so`), which `dlopen`s a library exporting `CrashpadHandlerMain` and
  calls it.
- That library is **ours**: on Android `fl_crashpad_native` also links
  `//handler` and `crashpad_handler_main`, and `exports/android.map` adds
  `CrashpadHandlerMain`. One library, so the client and the handler cannot
  come from different builds, and there is no `.rev` check to make.
- The shim finds both through `dladdr` on itself — the path is
  `…/base.apk!/lib/x86_64/libfl_crashpad_native.so` when the app keeps its
  libraries in the APK, which is the default — and passes
  `LD_LIBRARY_PATH=<that directory>` so the trampoline finds us by name.
- **At crash, not persistent.** No process idles in the background. A
  persistent handler (`…WithLinkerForClient`) would only have been needed for
  Crashpad's upload thread, which Dart replaces.
- Attachments go in as `--attachment=` arguments: the linker entry points
  drop them.
- **API 29 is checked at `start`** (`FL_CRASHPAD_UNSUPPORTED`); the library
  is built for **API 26**, the lowest Crashpad compiles for
  (`__system_property_read_callback`). Below 26 it does not load, which
  `isAvailable` reports as false.

**Android's handler cannot upload over https.** Its transport is `socket`,
and BoringSSL is wired up only inside Chromium or Fuchsia
(`util/net/tls.gni`). Hence the Dart uploader (`lib/src/uploader.dart`):
- **The handler is never given a URL on mobile.** Every report is parked;
  `start` runs `processReports(decide: true)` and then `uploadPending` on the
  backlog isolate. iOS does the same, although NSURLSession could upload, so
  that mobile has one upload path, the one proved here.
- **Byte parity with `CrashReportUploadThread::UploadReport`**, checked
  against the source: fields from `BreakpadHTTPFormParametersFromMinidump`
  through `fl_crashpad_report_upload_fields`, sorted; files in one sorted map
  (the minidump is *among* the attachments, keyed `upload_file_minidump`);
  `EncodeMIMEField` escapes `%` `"` CR LF with lowercase hex on the part name
  only; `---MultipartBoundary-<32>---`; gzip; `product`/`version`/`guid` on
  the URL; a 200 records the body as the remote id.
- **Outcomes go back into Crashpad's database** through
  `fl_crashpad_database_record_upload`: sent (`RecordUploadComplete`),
  failed (released, which records an attempt; skipped after five, Crashpad's
  iOS policy), or skipped — what Crashpad's handler does to a report when
  uploads are off, so `held` reports read the same as on desktop.
- The fields call is in the desktop library too, which is why
  `test/uploader_test.dart` runs under `dart test` against real crashes.

**An app may upload its own way** (`CrashReportDatabase.recordUpload`, added
2026-09-30 for ripple_effect, which sends to object storage through its own
client). It is a record, not a transport: the package still sends nothing an
app did not hand it, and the files it hands over are the sanitised ones.
- **Crashpad records an upload only of a pending report**
  (`GetReportForUploading`), and a held report is completed. So
  `recordOwnUpload` asks for it first (`RequestUpload`, which moves it back),
  then records `SENT` — no new native entry point, and the ABI stays 2.
- **A report already uploaded is refused**, as `reportNotFound`: Crashpad's
  `RequestUpload` refuses one too, but as a database error, which reads as a
  broken disk rather than a second call.
- **The race is documented, not closed.** A desktop handler given a URL can
  send a report between the app reading it and recording it. An app
  uploading its own way gives it none, and the doc comment says so.

**iOS: in process.** `StartCrashpadInProcessHandler(db, "", annotations)`.
The empty URL means no upload thread. `fl_crashpad_process_pending_dumps`
(`ProcessIntermediateDumps`, which blocks) runs first on the backlog isolate,
turning last session's intermediate dump into a report. The 500 ms pre-start
sanitise is skipped on mobile: nothing sends a report unattended.

**No 32-bit Android.** mini_chromium's toolchain sets `tool_prefix` and never
uses it for `target_cpu="arm"`, and GN fails the unused assignment. The fix is
a patch upstream, which this package never makes.

**The lock and the cache grew, not changed.** Four targets were added (`android-x64`,
`android-arm64`, `ios-arm64`, `ios-simulator` universal). A mobile archive
holds `lib/` only. The cache root now comes from the *host* OS
(`Platform.operatingSystem`), since an Android build is made on any of three.

## Sanitising: the rules, and when they run

**Every report is sanitised before anything can read or send it**, and that is
a feature of the package, not an option an app has to remember. The user asked
for it on 2026-09-29, with the rules copied from ripple_telemetry.

**The rules are ripple_telemetry's `Redactor`, copied rule for rule and in the
same order** (`lib/src/sanitizer.dart`). `test/fixtures/redaction.json` is its
fixture **copied verbatim**, so a diff against
`packages/ripple_telemetry/test/fixtures/redaction.json` must stay empty. When
that fixture changes, copy it again and make `sanitizer_test.dart` pass. The
one deliberate difference is a token: a project root there is a sensitive root
here, and a general-purpose package says `<private>`. Three rules are added,
each for something a log line never carries:
- **Secret-named environment variables.** `\b` cannot find `TOKEN` inside
  `GITHUB_TOKEN`, so the log rules miss every conventional name.
- **Literal `secrets`** an app names.
- **`sensitiveRoots`**, the project-root equivalent.

**The one rule that removes less than the log redactor's:** an email whose
domain is a version and `.so` — `android.hardware.drm@1.4.so` — is kept. The
first Android report had every HIDL library in its module list masked as
`<email>***`, and the module names are what symbols are found by. Pinned in
`sanitizer_test.dart`, proved able to fail; `rulesVersion` went to 2.

Swapping the email and username rules turns `ada@example.com` into
`<user>@example.com`; the fixture catches it, and was proved to.

**One implementation, two outputs.** `_Tracked` replays the redactor
faithfully, one rule after another, with each rule seeing what the previous
ones left. It also remembers which *original* characters each replacement
covered, using the prefix and suffix the replacement kept: `Bearer ` in front,
the basename behind. That gives:
- **`sanitizeText`**: the log redactor's exact string, used for text
  attachments.
- **`sanitizeBytes`**: every masked span overwritten in place with
  `<kind>***` of the *same length*. It works over UTF-8 runs and over UTF-16LE
  runs at both alignments, skipping mostly-CJK "runs" (UTF-8 misread two bytes
  at a time). Nothing moves, so the minidump still parses — checked on real
  dumps, where the crashing function is still found.

**In place, never via a temporary file and a rename.** macOS keeps a report's
metadata in extended attributes on the `.dmp` itself, and a rename would drop
them. `FileMode.append` opens for reading and writing without truncating;
only changed ranges are written.

**Why consent moved out of Crashpad** (`lib/src/report_store.dart`, which
carries the full argument):
- **The handler uploads from its own process right after the crash**, before
  any Dart can run.
- **So Crashpad's "uploads enabled" setting stays off while sanitising is
  on**, and the handler parks every report as skipped.
- **The package's consent lives in `<db>/fl_crashpad/settings.json`.** A
  marker per report, `<db>/fl_crashpad/reports/<id>.json`, records the rules
  version and the decision.
- **The next `start` sanitises before launching the handler**, within a 500 ms
  budget with the backlog finished on an isolate, then calls `RequestUpload`.
- **`RequestUpload` moves a skipped report back to pending as explicitly
  requested** (generic, macOS and Windows databases all do). An explicit
  upload bypasses both the setting and the rate limit.
- **The new handler's first pass sends it**, because its upload thread starts
  with an immediate pass. Anything requested later goes on the next 15-minute
  pass.
- **The upload's form fields are read back out of the minidump**
  (`BreakpadHTTPFormParametersFromMinidump`), so they are sanitised too.

**Proved end to end, and proved able to fail.** In `crash_test.dart`:
- Every crash test first requires the **raw** dump to hold `$HOME` and the
  planted email, then requires `reports()` to hand back neither.
- The upload test runs a local HTTP server. With consent on, a crash sends
  nothing from the dying process. The next start sends it, and what the server
  receives holds neither.
- With `disableSanitization: true` in the crasher, all five go red, the upload test with
  "sent from the crashed process".

**Measured**: a 16.8 MB dump (a thread stack overflow) takes 200–500 ms and
masks about 1,100 bytes. After it, no copy of the home directory or the account
name is left anywhere in the file. Typical dumps are 100–400 KB and take
milliseconds.

**What it cannot do**: know what a stack held of the user's *documents*. The
README says so. It errs towards taking too much: `PWD=` loses its value,
because `pwd` also means password in the copied rules, and a four-part version
string reads as an IP.

## Traps already paid for

- **Never `dart run` a child of the test runner in this package.** `dart run`
  re-runs the hook, which rewrites `.dart_tool/lib/libfl_crashpad_native.so`
  in place while the runner has it mapped. A page not yet written is then read
  back without its relocations, and the *runner* segfaults, calling
  `0xe3c6`-style addresses. The crasher is its own package (`test/crasher/`),
  built once with `dart build cli` into a bundle with its own copy.
- **archive 4's `extractArchiveToDisk` is async.** Un-awaited, it unpacked one
  file and reported success. `unawaited_futures` is on for that reason.
- **Don't depend on `meta` above Flutter's pin** (1.17.0): every Flutter
  consumer's resolution fails. The package does not use it.
- **A `.pubignore` pattern is anchored or it matches at any depth.** 1.0.0
  went to pub.dev without `lib/src/build/native_artifacts.dart`, because the
  `.pubignore` said `build/` where the `.gitignore` said `/build/`: every
  consumer's build hook failed, pub.dev scored the package 0/50 for analysis
  and 0/20 for platforms, and `pub publish --dry-run` said 0 warnings — it
  does not resolve imports. `test/pubignore_test.dart` asks git, with the
  `.pubignore` as the only ignore file, whether any tracked file under
  `lib/`, `hook/` or `bin/` would be left out.
- **Windows runners:** the first `tar` on PATH is Git's GNU tar, which reads
  `C:\…` as a host, so the script calls System32's bsdtar. `python3` may not
  exist, so the overlay copy of the dotfile says `python` when it doesn't.

**Android traps, each paid for on 2026-09-29:**
- **`am start --esa` crashes FlutterActivity**: it reads
  `dart_entrypoint_args` as a list, so it is `--esal`.
- **`run-as` needs a debuggable app**, so the e2e check builds debug.
- **`adb shell` joins its arguments into one remote command line.** A
  `sh -c '…'` has to be passed as a single, already-quoted string.
- **An `am start` too soon after a crash starts nothing**, and without
  `-S -f 0x10008000` (new task, clear task) Android may recreate the activity
  from the task's *first* intent: the app then ran with an earlier launch's
  `--upload` port. The e2e tool waits for `pidof` to go empty and clears the
  task.
- **An idle emulator's screen goes off, and Android cuts a background app's
  network**: the upload fails with `ECONNABORTED`, which looks like a
  firewall. `dumpsys netpolicy` shows `blocked=DOZE|APP_BACKGROUND` on the
  uid. It is *not* Android 17's local-network permission: an app targeting
  36 has `ACCESS_LOCAL_NETWORK` granted implicitly, and *declaring* it makes
  it a runtime permission that starts denied. `adb reverse` carried no
  traffic at all on this emulator, even from the shell. The e2e tool wakes
  the device and keeps it on.
- **bionic's `std::mutex` has a destructor**, so `-Wexit-time-destructors`
  fails the globals that compiled on Linux; they are leaked singletons now.

## Releasing the Dart half

Bump `version` in `pubspec.yaml`, turn `## Unreleased` into `## <version>` in
the CHANGELOG, merge, then run **Actions → publish** on the default branch. It
tags `v<version>`, cuts the GitHub release with that CHANGELOG section as its
notes, and publishes to pub.dev with GitHub's OIDC token, so no credential
lives anywhere. Pushing a `v*` tag, or creating a release in the UI, only
publishes. `.github/workflows/publish.yml` says why it dispatches itself on
the tag, and what pub.dev's admin page must allow for that.

The native half is released separately, below, and a Dart release never
rebuilds it.

## Releasing the native half

**Two versions, released separately.** The pubspec's `version` is the Dart
package on pub.dev. `artifacts` in `native/artifacts.lock.json` is the native
half: the compiled library, handler and trampoline for nine targets. They
start equal (0.1.0) and need not stay so.
- **A Dart-only change** — the API, the sanitiser, the uploader, docs — is a
  package release that keeps the lock as it is, and every app keeps
  downloading the same archives.
- **A change to what the native half is** — anything under `native/`, the
  Crashpad pin or its dependencies in the lock, the gn args or flags in
  `tool/build_native.dart` — needs a new `artifacts` version, a native
  release, and then a package release carrying the new lock. An old package
  keeps pointing at its old archives, which is what lets both coexist in the
  cache.
- `FL_CRASHPAD_ABI_VERSION` in `fl_crashpad.h` guards the pairing at run
  time: a library speaking another ABI makes `isAvailable` false and `start`
  throw, rather than being misread. Bump it (and `abiVersion` in
  `lib/src/ffi/bindings.dart`) with any change to the header; a native
  release that leaves the header alone keeps it.

**What the lock is.** The package's whole contract with its binaries: what
they are built from (the Crashpad revision, each dependency, gn and ninja),
the `artifacts` version, `release.baseUrl`, and one sha256 per target. It is
spelled once in JSON and generated as `artifacts.lock.cmake` and
`artifacts.lock.txt` for CMake and the pod by `tool/update_lock.dart`;
`artifacts_test` fails if the three disagree. `baseUrl` says
`native-v{artifacts}`, which `ArtifactLock.releaseBaseUrl` fills in, so the
tag in the URL cannot be left behind by a bump — `artifacts_test` fails a
URL with the tag written out by hand.

**What an app's build does with it.** Nothing is compiled. The hook, CMake
and the pod each look for their target in `artifacts_dir` /
`FL_CRASHPAD_ARTIFACTS_DIR`, then in the per-user cache under
`<artifacts>/<target>/` (complete only with its `.complete` stamp), and
otherwise download `fl_crashpad-native-<artifacts>-<target>.tar.gz` from
`baseUrl`. A download that does not match the lock's digest is unpacked
nowhere, and a target whose digest is still `null` stops the build with the
from-source instructions. `dart run fl_crashpad:prefetch` fills the cache
ahead of time.

**The procedure:**
1. Bump `artifacts` if the native half changed, run
   `dart run tool/update_lock.dart` to regenerate the copies, and land that on
   `main` with a green `native.yml` dispatch.
2. Tag `native-v<artifacts>` and push the tag. `native.yml` builds every
   target, tests each, and drafts a release with the archives, `SHA256SUMS`,
   and the exact `dart run tool/update_lock.dart target=sha …` command. The
   release job refuses a tag whose version isn't the archives' (the lock's
   `artifacts`).
3. **Publish the draft.** A draft's files are private, so until then every
   download the lock makes 404s. It is left a draft so that somebody looks at
   it first, not so that it stays one.
4. Run the command, commit the three lock files, and release the Dart half
   as above. The digests are recorded by hand, so no digest is trusted that
   nobody looked at.

**Never re-tag or replace an archive** of a published `native-v`: the digest
in every released lock pins those exact bytes, and a changed file fails every
build that has not cached it. A fix is a new `artifacts` version.

## Not yet verified (as of 2026-09-29)

`native-v0.1.0` (2026-09-29, `b473820`) is the first native release: the
whole matrix green in one tagged run — the native build and `dart test` (real
crashes, sanitised, uploaded to a local server) on linux-x64, linux-arm64,
windows-x64, windows-arm64 and macos-universal; the example's headless crash
on Linux and Windows x64; the macOS app built and `codesign --verify`'d; the
iOS builds; the Android e2e on an emulator — and the release job, whose
digests were recomputed from the downloaded archives before the draft was
published. From the live release, into an empty cache: `prefetch
--all-targets` on Linux, the whole `dart test` against the downloaded
linux-x64 library, and `cmake/fetch_artifact.cmake` for the handler. Still
unproved:
- **iOS at run time**: the in-process start, `ProcessIntermediateDumps` and
  the upload. CI builds the library and the example but runs nothing; an
  end-to-end check like `tool/android_e2e.dart` is still to be written, on a
  Mac. The example takes `--crash=` only through Android's intent so far.
- A Developer ID–signed macOS app. (Windows fast-fail through WER has a
  test on the Windows runners since 2026-09-30.)
- android-arm64 on hardware (x86_64 on an emulator is verified end to end).
- The download path on macOS (the pod's `embed_handler.sh`) and on Windows
  against the live release; the Linux hook, `prefetch` and CMake are proved.

## The example

`example/` is the end-to-end check and the demo: start, annotate, crash in
each way `CrashpadTestCrash` names, and open any report — the exception and
the module it happened in, both kinds of annotation, the system, the
attachments and every module. `example/lib/minidump.dart` is the reader behind
that page. It lives in the example rather than the package on purpose: the
package writes and ships reports, and does not claim to read them; if a host
wants a consent screen that shows what would be sent, promoting it is the
obvious next step. Its offsets are pinned by `example/test/minidump_test.dart`
against a minidump built byte by byte, and were checked against real dumps:
a `segfault` lands in `libfl_crashpad_native.so` at an offset inside
`fl_crashpad_crash_for_testing`, an `abort` in libc's `raise`.

On Linux a minidump's exception *address* is the faulting data address — 0 for
a write through null — so "where" comes from the crashing thread's instruction
pointer in its register context, not from the exception record.

The report page shows where a report is stored through the same sanitiser,
and "Sent as `<id>.dmp`" beside it, because a path on screen next to "what
would be sent" reads as though the path is sent. It never is:
- **The minidump** travels under `<report id>.dmp`.
- **An attachment** travels under its file name alone. The Linux handler
  takes `BaseName()` when it copies one in, and that name is not sanitised,
  so an app should not name attachment files after the user.
- **Paths inside the dump** are masked like everything else.

