# Changelog

What an app can do with each version, newest first. The reasoning behind a
change lives beside the code in `CLAUDE.md`; this file only says what changed.

## 1.0.1

- **1.0.0 could not be built.** Its archive on pub.dev was missing
  `lib/src/build/native_artifacts.dart`, which the build hook and
  `dart run fl_crashpad:prefetch` import, so every build that depended on it
  failed. Nothing else changed: the same API, the same `native-v0.1.0`
  archives.
- `hooks` and `code_assets` are accepted at either 1.x or 2.x, whichever the
  app's other plugins resolve.

## 1.0.0

The API is stable from here. The native half is unchanged — the same
`native-v0.1.0` archives, the same digests — and so is everything on disk: a
user's consent given under 0.1 is still their consent.

The changes are to what the API says to whoever reads a call to it. Consent
reads as consent, the one switch that sends a user's data out as it was
written reads as the decision it is, and a name that answered two questions
now answers the one it can.

### Renamed

| 0.1.0 | 1.0.0 |
| --- | --- |
| `CrashpadOptions(uploadsEnabled: …)` | `CrashpadOptions(uploadConsent: …)` |
| `database.uploadsEnabled` | `database.uploadConsent` |
| `CrashpadOptions(sanitize: false)` | `CrashpadOptions(disableSanitization: true)` |
| `CrashpadOptions(upload: CrashpadUpload(url: …))` | `CrashpadOptions(uploadEndpoint: CrashpadUploadEndpoint(url: …))` |
| `CrashpadOptions(annotations: …)` | `CrashpadOptions(fixedAnnotations: …)` |
| `Crashpad.isSupported` | `Crashpad.isAvailable` |

- **`uploadConsent`** (`null`: keep the last answer, which is `false` until
  somebody says otherwise). It is the user's answer, not a switch on the
  uploader, and its doc says to pass what they answered rather than `true`
  because an endpoint exists. The settings file keeps its `uploadsEnabled`
  key, so no consent already given is withdrawn. *consent given under 0.1 is
  still consent* in `test/api_test.dart`.
- **`disableSanitization`** (`false`). Sanitising is the default you never
  write; the other path is one deliberate, conspicuous line.
- **`CrashpadUploadEndpoint`** under **`uploadEndpoint`**: it is where reports
  go, not an upload.
- **`fixedAnnotations`**: they never join the runtime `Crashpad.annotations`
  and nothing changes them after `start`.
- **`isAvailable`**: whether this build carries the native library in the
  version this code speaks. `isSupported` answered `true` on Android 8 and 9,
  where `start` then refuses; the doc now lists what `start` can still refuse
  with, as a `CrashpadErrorCode` to branch on.

### Removed from the barrel

- `sanitizeReportFiles`: what the database calls on each report, documented
  for nobody else. `ReportSanitizer` is the API.

### Documentation

- `crashForTesting` says first that it terminates the process;
  `CrashpadHandler` says it is for custom packaging.
- The README follows the order an app is set up in — install, start, what you
  get, sanitising, consent and uploads, reading reports, trying it out, then
  the platforms and how the native half gets built — and says what
  sanitising cannot catch beside the promise it makes, not after it.
- `SECURITY.md`: what the package promises, what it cannot, what you are
  running and how it is verified, and how to report a vulnerability.

### Android and iOS, and since 0.1.0

- **Windows**: `Crashpad.start` lists `crashpad_wer.dll` in the registry under
  the current user, so fast-fail crashes — a `/GS` failure, a Rust abort —
  are reported with no installer step (`registerWerModule`, `true`). It also
  lets WER see the process, which the Dart runtime's error mode had stopped,
  asking WER for no crash dialog in its place.

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
  sends at once when `start` was given a `CrashpadOptions.uploadEndpoint`.
- `Crashpad.sanitizationIdle` also covers the upload on mobile.
- Android's versioned system libraries (`android.hardware.drm@1.4.so`) are no
  longer masked as email addresses; `ReportSanitizer.rulesVersion` is 2.
- The native ABI is 2.
- `CrashReportDatabase.recordUpload(id, remoteId:)` records a report the app
  sent its own way, from any state, so a backend that is not a minidump
  collector needs no `CrashpadOptions.uploadEndpoint`.
- `CrashReport.attachments`: a report's attachments, sanitised like its
  minidump (`[]` when there are none).

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
