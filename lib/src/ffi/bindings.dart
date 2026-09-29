// The C ABI of native/include/fl_crashpad.h, one declaration per function.
//
// Resolved through the code asset hook/build.dart registers, so there is no
// DynamicLibrary.open and no path to get wrong: the SDK bundles the library
// and knows where it put it. Keep this file in step with the header — the
// struct layout above all, since a field out of order is a crash, not an
// error.
@DefaultAsset('package:fl_crashpad/fl_crashpad_native')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The ABI these declarations were written against. The library reports its
/// own; the two must match or nothing else here is called.
const int abiVersion = 2;

// fl_crashpad_status
const int statusOk = 0;
const int statusInvalidArgument = 1;
const int statusAlreadyStarted = 2;
const int statusHandlerMissing = 3;
const int statusHandlerNotExecutable = 4;
const int statusHandlerFailedToStart = 5;
const int statusRevisionMismatch = 6;
const int statusDatabaseError = 7;
const int statusReportNotFound = 8;
const int statusLimitExceeded = 9;
const int statusUnsupported = 10;
const int statusReportNotPending = 11;

// fl_crashpad_upload_outcome
const int uploadSent = 0;
const int uploadFailed = 1;
const int uploadSkipped = 2;

// fl_crashpad_config.flags
const int flagUploadsEnabled = 1 << 0;
const int flagNoRateLimit = 1 << 1;
const int flagNoUploadGzip = 1 << 2;
const int flagNoIdentifyClientViaUrl = 1 << 3;
const int flagNoPeriodicTasks = 1 << 4;

final class NativePair extends Struct {
  external Pointer<Utf8> key;
  external Pointer<Utf8> value;
}

final class NativeConfig extends Struct {
  @Uint32()
  external int structSize;
  @Uint32()
  external int flags;
  external Pointer<Utf8> handlerPath;
  external Pointer<Utf8> databasePath;
  external Pointer<Utf8> metricsPath;
  external Pointer<Utf8> url;
  external Pointer<NativePair> annotations;
  @Size()
  external int annotationCount;
  external Pointer<Pointer<Utf8>> attachments;
  @Size()
  external int attachmentCount;
  external Pointer<Pointer<Utf8>> arguments;
  @Size()
  external int argumentCount;
  external Pointer<Utf8> werModulePath;
}

@Native<Uint32 Function()>(symbol: 'fl_crashpad_abi_version', isLeaf: true)
external int nativeAbiVersion();

@Native<Pointer<Utf8> Function()>(
  symbol: 'fl_crashpad_crashpad_revision',
  isLeaf: true,
)
external Pointer<Utf8> nativeCrashpadRevision();

// Not a leaf: it spawns the handler and, on macOS and Windows, waits for it.
@Native<Int32 Function(Pointer<NativeConfig>, Pointer<Pointer<Utf8>>)>(
  symbol: 'fl_crashpad_start',
)
external int nativeStart(
  Pointer<NativeConfig> config,
  Pointer<Pointer<Utf8>> error,
);

@Native<Bool Function()>(symbol: 'fl_crashpad_is_started', isLeaf: true)
external bool nativeIsStarted();

@Native<Int32 Function(Pointer<Utf8>, Pointer<Utf8>)>(
  symbol: 'fl_crashpad_annotation_set',
  isLeaf: true,
)
external int nativeAnnotationSet(Pointer<Utf8> key, Pointer<Utf8> value);

@Native<Int32 Function(Pointer<Utf8>)>(
  symbol: 'fl_crashpad_annotation_remove',
  isLeaf: true,
)
external int nativeAnnotationRemove(Pointer<Utf8> key);

@Native<Void Function()>(symbol: 'fl_crashpad_annotation_clear', isLeaf: true)
external void nativeAnnotationClear();

@Native<Void Function()>(symbol: 'fl_crashpad_dump_without_crash')
external void nativeDumpWithoutCrash();

@Native<Void Function(Int32)>(symbol: 'fl_crashpad_crash_for_testing')
external void nativeCrashForTesting(int kind);

@Native<Int32 Function(Pointer<Utf8>, Pointer<Bool>, Pointer<Pointer<Utf8>>)>(
  symbol: 'fl_crashpad_database_get_uploads_enabled',
)
external int nativeDatabaseGetUploadsEnabled(
  Pointer<Utf8> databasePath,
  Pointer<Bool> enabled,
  Pointer<Pointer<Utf8>> error,
);

@Native<Int32 Function(Pointer<Utf8>, Bool, Pointer<Pointer<Utf8>>)>(
  symbol: 'fl_crashpad_database_set_uploads_enabled',
)
external int nativeDatabaseSetUploadsEnabled(
  Pointer<Utf8> databasePath,
  bool enabled,
  Pointer<Pointer<Utf8>> error,
);

@Native<
  Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>)
>(symbol: 'fl_crashpad_database_reports')
external int nativeDatabaseReports(
  Pointer<Utf8> databasePath,
  Pointer<Pointer<Utf8>> json,
  Pointer<Pointer<Utf8>> error,
);

@Native<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
  symbol: 'fl_crashpad_database_request_upload',
)
external int nativeDatabaseRequestUpload(
  Pointer<Utf8> databasePath,
  Pointer<Utf8> reportId,
  Pointer<Pointer<Utf8>> error,
);

@Native<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Utf8>>)>(
  symbol: 'fl_crashpad_database_delete_report',
)
external int nativeDatabaseDeleteReport(
  Pointer<Utf8> databasePath,
  Pointer<Utf8> reportId,
  Pointer<Pointer<Utf8>> error,
);

@Native<Void Function(Pointer<Void>)>(symbol: 'fl_crashpad_free', isLeaf: true)
external void nativeFree(Pointer<Void> pointer);

@Native<
  Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Pointer<Utf8>>)
>(symbol: 'fl_crashpad_report_upload_fields')
external int nativeReportUploadFields(
  Pointer<Utf8> minidumpPath,
  Pointer<Pointer<Utf8>> json,
  Pointer<Pointer<Utf8>> error,
);

@Native<
  Int32 Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Int32,
    Pointer<Utf8>,
    Pointer<Pointer<Utf8>>,
  )
>(symbol: 'fl_crashpad_database_record_upload')
external int nativeDatabaseRecordUpload(
  Pointer<Utf8> databasePath,
  Pointer<Utf8> reportId,
  int outcome,
  Pointer<Utf8> response,
  Pointer<Pointer<Utf8>> error,
);

// Not a leaf, and never on the UI isolate: it blocks while it writes reports.
@Native<Void Function()>(symbol: 'fl_crashpad_process_pending_dumps')
external void nativeProcessPendingDumps();
