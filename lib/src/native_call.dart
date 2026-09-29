import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'exception.dart';
import 'ffi/bindings.dart';

/// Runs one fallible call into the C ABI: gives it an arena and an error
/// out-parameter, and turns a non-zero status into a [CrashpadException]
/// carrying the library's message. The message is freed here either way.
T callNative<T>(
  (int status, T result) Function(Arena arena, Pointer<Pointer<Utf8>> error)
  call,
) => using((arena) {
  final error = arena<Pointer<Utf8>>()..value = nullptr;
  final (status, result) = call(arena, error);
  final message = error.value == nullptr ? null : error.value.toDartString();
  if (error.value != nullptr) nativeFree(error.value.cast());
  if (status != statusOk) {
    throw CrashpadException(
      codeForStatus(status),
      message ?? 'fl_crashpad failed with status $status',
    );
  }
  return result;
});

CrashpadErrorCode codeForStatus(int status) => switch (status) {
  statusInvalidArgument => CrashpadErrorCode.invalidArgument,
  statusAlreadyStarted => CrashpadErrorCode.alreadyStarted,
  statusHandlerMissing => CrashpadErrorCode.handlerMissing,
  statusHandlerNotExecutable => CrashpadErrorCode.handlerNotExecutable,
  statusHandlerFailedToStart => CrashpadErrorCode.handlerFailedToStart,
  statusRevisionMismatch => CrashpadErrorCode.revisionMismatch,
  statusDatabaseError => CrashpadErrorCode.databaseError,
  statusReportNotFound => CrashpadErrorCode.reportNotFound,
  statusLimitExceeded => CrashpadErrorCode.limitExceeded,
  statusUnsupported => CrashpadErrorCode.unsupportedPlatform,
  statusReportNotPending => CrashpadErrorCode.reportNotFound,
  // A status this Dart code has never heard of came from a newer library.
  _ => CrashpadErrorCode.incompatibleLibrary,
};
