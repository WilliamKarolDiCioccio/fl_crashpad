/// What went wrong, as something a program can branch on.
enum CrashpadErrorCode {
  /// A platform without a build, an Android older than 10, or a build the
  /// native library is not part of.
  unsupportedPlatform,

  /// The native library speaks a different ABI than this Dart code.
  incompatibleLibrary,

  /// Crashpad is already running in this process. It cannot be restarted.
  alreadyStarted,

  /// macOS App Sandbox: not supported in this version.
  sandboxed,

  /// An argument the native side refused.
  invalidArgument,

  /// There is no `crashpad_handler` at the path given or derived.
  handlerMissing,

  /// The handler is there but has lost its executable bit.
  handlerNotExecutable,

  /// The handler would not start. On Linux this includes a handler that
  /// cannot run at all — built for another architecture, say, or on a
  /// `noexec` mount.
  handlerFailedToStart,

  /// The handler and the library come from different Crashpad builds.
  revisionMismatch,

  /// The report database could not be opened, read or written.
  databaseError,

  /// No report has that id, or none in the state the call needs.
  reportNotFound,

  /// A runtime annotation would be one entry more than Crashpad keeps.
  limitExceeded,
}

/// A failure reported by Crashpad or by this package's checks around it.
class CrashpadException implements Exception {
  const CrashpadException(this.code, this.message);

  final CrashpadErrorCode code;
  final String message;

  @override
  String toString() => 'CrashpadException(${code.name}): $message';
}
