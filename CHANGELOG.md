# Changelog

What an app can do with each version, newest first. The reasoning behind a
change lives beside the code in `CLAUDE.md`; this file only says what changed.

## Unreleased

Android and iOS.

- **Android** 10 and later, arm64-v8a and x86_64: the handler is the library
  itself, started at a crash by the system linker through
  `libcrashpad_handler_trampoline.so`. Both travel through the build hook,
  with nothing to add to the app. Nothing runs until a crash.
- **iOS**: crashes are caught in process and become reports on the next
  launch. `attachments`, `handlerArguments`, `metricsDirectory` and
  `periodicTasks` do nothing there.
- On both, reports are uploaded by the package from Dart, on the launch after
  the crash, once sanitised — the same request Crashpad's handler sends, which
  on Android cannot speak https. A report that cannot be sent is tried again
  on later launches, five times in all. `CrashReportDatabase.requestUpload`
  sends at once when `start` was given a `CrashpadOptions.upload`.
- `Crashpad.sanitizationIdle` also covers the upload on mobile.
- Android's versioned system libraries (`android.hardware.drm@1.4.so`) are no
  longer masked as email addresses; `ReportSanitizer.rulesVersion` is 2.
- The native ABI is 2.

## 0.1.0

The first release: native crash reporting for Flutter desktop apps on Linux,
Windows and macOS, x64 and arm64, over Google Crashpad (`ce308a86`).

- `Crashpad.start(CrashpadOptions)` starts the handler and installs
  process-wide crash handlers: a crash anywhere in the process — the engine, a
  plugin, a native library loaded over FFI — leaves a minidump in
  `databaseDirectory`. A handler that is missing, not executable, from another
  Crashpad build or unable to run is refused with a `CrashpadException` rather
  than trusted.
- Reports are sanitised before they can be read or sent
  (`CrashpadOptions.sanitize`, `true`): the home directory, the account name,
  emails, credentials, secret-named environment variables, IP addresses and
  private paths are masked inside the minidump in place, byte for byte, and
  text attachments are rewritten. While it is on, a report is uploaded on the
  launch after the crash, once cleaned. `ReportSanitizer` carries the rules;
  `ReportSanitizer.forHost(secrets:, sensitiveRoots:)` adds an app's own.
  `CrashReport.sanitized` says a report has been through it.
- `CrashpadOptions.annotations`, fixed at start, and `Crashpad.annotations`,
  changeable at any time and usable before `start`, within Crashpad's limits of
  64 entries and 255-byte keys and values.
- `CrashpadOptions.attachments`, read at the moment of the crash.
- `CrashpadUpload` for any minidump endpoint, and
  `CrashpadOptions.uploadsEnabled` (`null`, keeping the last answer, which
  starts as `false`) as consent kept in the database.
- `CrashReportDatabase`: consent, pending and completed reports, upload
  requests (`Future<void> requestUpload`) and deletion, before `start` and
  from any isolate.
- `Crashpad.dumpWithoutCrash()` and `Crashpad.crashForTesting()`.
- `CrashpadOptions.registerWerModule` (`true`): Windows fast-fail crashes,
  Rust's `process::abort` among them, reported through `crashpad_wer.dll`.
- The native half arrives through Flutter's own build — the library through a
  build hook, the handler through the package's platform files — from a
  per-user cache filled by a verified download or by
  `tool/build_native.dart --install`. `dart run fl_crashpad:prefetch` fills it
  ahead of a build.
