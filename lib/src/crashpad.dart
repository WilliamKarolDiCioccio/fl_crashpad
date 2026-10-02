import 'dart:ffi';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'annotations.dart';
import 'exception.dart';
import 'ffi/bindings.dart';
import 'handler_location.dart';
import 'native_call.dart';
import 'options.dart';
import 'report_store.dart';
import 'sanitizer.dart';
import 'uploader.dart';
import 'wer_registration.dart';

/// The ways [Crashpad.crashForTesting] can end the process.
enum CrashpadTestCrash {
  /// A write through a null pointer: SIGSEGV, or an access violation.
  segfault,

  /// `abort()`: SIGABRT.
  abort,

  /// Unbounded recursion on a new native thread that has called
  /// `fl_crashpad_initialize_signal_stack_for_thread` first.
  stackOverflowOnThread,
}

/// Crashpad in this process.
///
/// Static, because there is exactly one: Crashpad installs process-wide crash
/// handlers, it can be started once, and it cannot be stopped. What it
/// catches is every crash of the *process* — a segfault, an abort, an access
/// violation — whichever code caused it: the Flutter engine, a plugin, or a
/// native library loaded over FFI, such as a Rust engine behind
/// flutter_rust_bridge. Exceptions thrown and caught in Dart are not crashes
/// and never reach it; report those through whatever the app already uses.
abstract final class Crashpad {
  static final CrashpadAnnotations _annotations =
      CrashpadAnnotations.internal();

  /// Whether this build carries the native library, in the version this
  /// Dart code speaks. Nothing else: **true is not a promise that [start]
  /// will succeed.**
  ///
  /// False on platforms without a build — anything but Linux, macOS,
  /// Windows, 64-bit Android from 8.0 (API 26) and iOS — and in a build that
  /// opted out with the `disable` user-define. Where it is true, [start] can
  /// still refuse, with a [CrashpadException] whose [CrashpadException.code]
  /// says why:
  ///
  /// - [CrashpadErrorCode.unsupportedPlatform] on Android 8 and 9, which load
  ///   the library but cannot run the handler: it needs Android 10;
  /// - [CrashpadErrorCode.sandboxed] inside the macOS App Sandbox;
  /// - the handler codes, when the handler is missing or not the one built
  ///   with this library.
  ///
  /// So check this to skip crash reporting where there is none, and catch
  /// from [start] for the rest. It was `isSupported` until 1.0, which read as
  /// the answer to the second question as well.
  static bool get isAvailable => _libraryAbi() == abiVersion;

  /// Whether [start] has succeeded in this process.
  static bool get isStarted => isAvailable && nativeIsStarted();

  /// The Crashpad revision the native library was built from.
  static String get crashpadRevision {
    _requireLibrary();
    return nativeCrashpadRevision().toDartString();
  }

  /// Runtime annotations: see [CrashpadAnnotations]. Usable before [start].
  static CrashpadAnnotations get annotations {
    _requireLibrary();
    return _annotations;
  }

  /// Starts the handler and installs the crash handlers.
  ///
  /// Call it once, as early as the app can — in `main`, before `runApp` —
  /// because nothing that crashes before it is caught. It is synchronous on
  /// purpose, and blocks for as long as the handler takes to start (tens of
  /// milliseconds): when it returns, the process is covered.
  ///
  /// On desktop the handler is checked first, so that a broken install fails
  /// here, loudly, rather than at the first crash, silently: it must exist, be
  /// executable, come from the same Crashpad build as the library and, on
  /// Linux, run.
  ///
  /// On Android and iOS nothing extra runs: Android starts its handler only at
  /// the moment of a crash, and iOS handles crashes inside the process. Their
  /// reports are uploaded by this package, on the launch after the crash, once
  /// sanitised — see [CrashpadOptions.upload].
  ///
  /// Throws a [CrashpadException] when anything prevents the start.
  static void start(CrashpadOptions options) {
    _requireLibrary();
    if (Platform.isMacOS &&
        Platform.environment.containsKey('APP_SANDBOX_CONTAINER_ID')) {
      throw const CrashpadException(
        CrashpadErrorCode.sandboxed,
        'the macOS App Sandbox is not supported yet: the handler would be '
        'refused the access it needs to the crashed process',
      );
    }

    final mobile = uploadsFromDart;
    final handler = mobile
        ? null
        : options.handler ?? CrashpadHandler.defaultPath();
    final werModule = options.registerWerModule
        ? CrashpadHandler.defaultWerModule()
        : null;
    final werModulePath = werModule != null && werModule.existsSync()
        ? werModule.path
        : null;
    // Before the handler starts, so a fast-fail from the first moment is
    // covered: WER reads the list when the crash happens, and the shim's
    // registration only names the module. See wer_registration.dart.
    if (werModulePath != null) {
      registerWerModuleInRegistry(werModulePath);
      letWerSeeFastFails();
    }
    final upload = options.uploadEndpoint;
    final database = options.databaseDirectory.path;

    // Consent and the mode are the package's, kept beside Crashpad's
    // database; see report_store.dart for why Crashpad's own setting stays
    // off while reports are sanitised.
    Directory(database).createSync(recursive: true);
    final settings = StoreSettings(
      uploadConsent:
          options.uploadConsent ?? StoreSettings.read(database).uploadConsent,
      sanitize: !options.disableSanitization,
    )..write(database);
    final sanitizer = options.sanitizer ?? ReportSanitizer.forHost();

    // Before the handler exists: what it finds pending when it starts is
    // what it sends on its first pass, so the reports it finds must already
    // be the cleaned ones. On mobile no handler sends anything, so all of it
    // can wait for the background.
    var backlog = mobile;
    if (settings.sanitize && !mobile) {
      try {
        backlog = !processReports(
          database,
          sanitizer,
          decide: true,
          budget: _startBudget,
        ).finished;
      } on Object {
        // Never a reason not to start: an unsanitised report stays parked,
        // unsent, until a later pass gets through it.
        backlog = true;
      }
    }

    var flags = 0;
    if (settings.crashpadUploadsEnabled && !mobile) flags |= flagUploadsEnabled;
    if (upload != null && !upload.rateLimit) flags |= flagNoRateLimit;
    if (upload != null && !upload.gzip) flags |= flagNoUploadGzip;
    if (upload != null && !upload.identifyClientViaUrl) {
      flags |= flagNoIdentifyClientViaUrl;
    }
    if (!options.periodicTasks) flags |= flagNoPeriodicTasks;

    callNative((arena, error) {
      Pointer<Utf8> string(String? value) =>
          value == null ? nullptr : value.toNativeUtf8(allocator: arena);

      Pointer<Pointer<Utf8>> strings(List<String> values) {
        if (values.isEmpty) return nullptr;
        final array = arena<Pointer<Utf8>>(values.length);
        for (var i = 0; i < values.length; i++) {
          array[i] = string(values[i]);
        }
        return array;
      }

      final annotations = options.fixedAnnotations.entries.toList();
      final pairs = annotations.isEmpty
          ? nullptr
          : arena<NativePair>(annotations.length);
      for (var i = 0; i < annotations.length; i++) {
        pairs[i]
          ..key = string(annotations[i].key)
          ..value = string(annotations[i].value);
      }

      final config = arena<NativeConfig>();
      config.ref
        ..structSize = sizeOf<NativeConfig>()
        ..flags = flags
        ..handlerPath = string(handler?.path)
        ..databasePath = string(options.databaseDirectory.path)
        ..metricsPath = string(options.metricsDirectory?.path)
        ..url = mobile ? nullptr : string(upload?.url.toString())
        ..annotations = pairs
        ..annotationCount = annotations.length
        ..attachments = strings([for (final f in options.attachments) f.path])
        ..attachmentCount = options.attachments.length
        ..arguments = strings(options.handlerArguments)
        ..argumentCount = options.handlerArguments.length
        ..werModulePath = werModulePath == null
            ? nullptr
            : string(werModulePath);

      return (nativeStart(config, error), null);
    });

    if (mobile) activeUpload = upload;
    if (backlog) {
      // The rest, off the caller's isolate. On desktop the handler is running
      // by now and sends these on its next pass, every fifteen minutes. On
      // mobile this is where last session's crash becomes a report (iOS),
      // is sanitised, and is sent.
      _backlog = Isolate.run(() async {
        if (mobile) nativeProcessPendingDumps();
        processReports(database, sanitizer, decide: true);
        if (mobile && upload != null) await uploadPending(database, upload);
      }).then((_) {}, onError: (Object _) {});
    }
  }

  /// How long [start] spends sanitising before it launches the handler.
  /// Enough for the report of the last crash — a few milliseconds for a
  /// typical minidump, a few hundred for one with a large stack — and no
  /// more, because nothing is caught until the handler runs.
  static const Duration _startBudget = Duration(milliseconds: 500);

  static Future<void>? _backlog;

  /// Completes once the reports [start] left for the background have been
  /// sanitised — and on mobile, sent — for a test, or for an app that wants
  /// to show them.
  static Future<void> get sanitizationIdle => _backlog ?? Future.value();

  /// Writes a report of the process as it is now, and carries on — for a
  /// state that is wrong but not fatal, and worth a look.
  ///
  /// Needs [start] to have run; before it, there is nobody to write the
  /// report and this does nothing.
  static void dumpWithoutCrash() {
    _requireLibrary();
    if (!nativeIsStarted()) return;
    nativeDumpWithoutCrash();
  }

  /// **Terminates the process**, on purpose, to prove a setup produces
  /// reports. Never returns: nothing after it runs, nothing is flushed, and
  /// the app is gone — so call it from an integration test or a hidden
  /// developer menu, never from a path a user can reach by accident.
  ///
  /// [dumpWithoutCrash] writes a report and carries on, for when the process
  /// should survive the check.
  static Never crashForTesting([
    CrashpadTestCrash kind = CrashpadTestCrash.segfault,
  ]) {
    _requireLibrary();
    nativeCrashForTesting(kind.index);
    // The native side aborts if it somehow survives its own crash.
    throw StateError('unreachable');
  }

  static int? _libraryAbi() {
    try {
      return nativeAbiVersion();
    } on ArgumentError {
      // The asset is not in this build: `@Native` lookups fail with an
      // ArgumentError naming the symbol. That is what "unsupported" means.
      return null;
    }
  }

  static void _requireLibrary() {
    final abi = _libraryAbi();
    if (abi == null) {
      throw CrashpadException(
        CrashpadErrorCode.unsupportedPlatform,
        'the fl_crashpad native library is not part of this build '
        '(${Platform.operatingSystem})',
      );
    }
    if (abi != abiVersion) {
      throw CrashpadException(
        CrashpadErrorCode.incompatibleLibrary,
        'the native library speaks ABI $abi; this package speaks $abiVersion',
      );
    }
  }
}
