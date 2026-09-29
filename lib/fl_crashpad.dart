/// Native crash reporting for Flutter apps with Google Crashpad.
///
/// Start it once, early:
///
/// ```dart
/// Crashpad.start(CrashpadOptions(
///   databaseDirectory: Directory('${support.path}/crashpad'),
///   annotations: {'version': '1.2.0'},
/// ));
/// ```
///
/// and every crash of the process — including one inside a native library
/// loaded over FFI — leaves a minidump in that directory, to read with
/// [CrashReportDatabase] or to upload to any minidump endpoint.
library;

export 'src/annotations.dart' show CrashpadAnnotations;
export 'src/crashpad.dart' show Crashpad, CrashpadTestCrash;
export 'src/database.dart'
    show CrashReport, CrashReportDatabase, CrashReportState;
export 'src/exception.dart' show CrashpadErrorCode, CrashpadException;
export 'src/handler_location.dart' show CrashpadHandler;
export 'src/options.dart' show CrashpadOptions, CrashpadUpload;
export 'src/sanitizer.dart' show ReportSanitizer, sanitizeReportFiles;
