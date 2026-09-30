import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'exception.dart';
import 'ffi/bindings.dart';
import 'native_call.dart';
import 'report_store.dart';
import 'sanitizer.dart';
import 'uploader.dart';

/// Whether a report is queued to be sent, or done with.
enum CrashReportState {
  /// Queued: an upload has been asked for and the handler has not finished
  /// it yet.
  pending,

  /// Sent, given up on, or held back — waiting for consent or for
  /// [CrashReportDatabase.requestUpload].
  completed,
}

/// One report in a [CrashReportDatabase].
class CrashReport {
  const CrashReport({
    required this.id,
    required this.state,
    required this.createdAt,
    required this.uploaded,
    required this.remoteId,
    required this.uploadAttempts,
    required this.uploadExplicitlyRequested,
    required this.minidump,
    this.attachments = const [],
    this.sanitized = false,
  });

  factory CrashReport.fromJson(
    Map<String, Object?> json, {
    List<File> attachments = const [],
    bool sanitized = false,
  }) => CrashReport(
    id: json['id']! as String,
    state: CrashReportState.values.byName(json['state']! as String),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt']! as int) * 1000,
      isUtc: true,
    ),
    uploaded: json['uploaded']! as bool,
    remoteId: switch (json['remoteId']) {
      final String id when id.isNotEmpty => id,
      _ => null,
    },
    uploadAttempts: json['uploadAttempts']! as int,
    uploadExplicitlyRequested: json['uploadExplicitlyRequested']! as bool,
    minidump: File(json['path']! as String),
    attachments: attachments,
    sanitized: sanitized,
  );

  /// Crashpad's id for the report, a UUID.
  final String id;
  final CrashReportState state;
  final DateTime createdAt;
  final bool uploaded;

  /// The id the server answered with, once uploaded.
  final String? remoteId;
  final int uploadAttempts;
  final bool uploadExplicitlyRequested;

  /// The `.dmp` file itself — already sanitised, when [sanitized].
  final File minidump;

  /// The files [CrashpadOptions.attachments] named, as they were at the
  /// crash — already sanitised, when [sanitized]. Sorted by path.
  final List<File> attachments;

  /// Whether the minidump and its attachments have been through the
  /// [ReportSanitizer]. Always true for a report [CrashReportDatabase.reports]
  /// returns while sanitising is on.
  final bool sanitized;

  @override
  String toString() => 'CrashReport($id, ${state.name}, $createdAt)';
}

/// The reports Crashpad has written to [directory], and the upload consent
/// kept beside them.
///
/// Usable whether or not [Crashpad.start] has run, and from any isolate — so
/// an app can record the user's choice before the handler ever starts, and
/// show last session's crash on the next launch.
///
/// **Every way to a report goes through the [sanitizer] first.** [reports]
/// sanitises any report not yet sanitised before returning it, and
/// [requestUpload] before asking for it to be sent; a report that cannot be
/// sanitised yet is left out rather than handed over raw. See
/// [CrashpadOptions.sanitize] for what that costs and how to turn it off.
class CrashReportDatabase {
  CrashReportDatabase(this.directory, {ReportSanitizer? sanitizer})
    : sanitizer = sanitizer ?? ReportSanitizer.forHost();

  final Directory directory;

  /// What reports are cleaned with.
  final ReportSanitizer sanitizer;

  /// Whether reports may be sent. Off until something turns it on.
  bool get uploadsEnabled => StoreSettings.read(directory.path).uploadsEnabled;

  set uploadsEnabled(bool enabled) {
    final current = StoreSettings.read(directory.path);
    final next = StoreSettings(
      uploadsEnabled: enabled,
      sanitize: current.sanitize,
    )..write(directory.path);
    setNativeUploadsEnabled(directory.path, next.crashpadUploadsEnabled);
  }

  /// Every report, newest first, each sanitised before it is returned.
  /// Reads — and when needed rewrites — the disk on another isolate.
  Future<List<CrashReport>> reports() {
    final path = directory.path;
    final sanitizer = this.sanitizer;
    return Isolate.run(() {
      final settings = StoreSettings.read(path);
      final processed = processReports(path, sanitizer, decide: false);
      return [
        for (final report in processed.reports)
          if (report.sanitized || !settings.sanitize)
            CrashReport.fromJson(
              report.json,
              attachments: _attachments(path, report.json['id']! as String),
              sanitized: report.sanitized,
            ),
      ];
    });
  }

  Future<List<CrashReport>> pendingReports() async => [
    for (final report in await reports())
      if (report.state == CrashReportState.pending) report,
  ];

  Future<List<CrashReport>> completedReports() async => [
    for (final report in await reports())
      if (report.state == CrashReportState.completed) report,
  ];

  /// Sanitises a report if it is not already, then asks for it to be sent
  /// whether or not uploads are enabled — for an app that asks the user about
  /// each crash rather than once. On desktop a running handler picks it up on
  /// its next pass (every fifteen minutes), and one that starts picks it up at
  /// once. On Android and iOS it is sent now, if [Crashpad.start] was given a
  /// [CrashpadOptions.upload] in this isolate, and otherwise on the next
  /// start that has one.
  Future<void> requestUpload(String reportId) async {
    final path = directory.path;
    final sanitizer = this.sanitizer;
    final upload = uploadsFromDart ? activeUpload : null;
    try {
      await Isolate.run(() async {
        sanitizeAndRequest(path, sanitizer, reportId);
        if (upload != null) await uploadPending(path, upload, only: reportId);
      });
    } on CrashpadNotFound {
      throw CrashpadException(
        CrashpadErrorCode.reportNotFound,
        'no report $reportId',
      );
    }
  }

  /// Records that the app sent [reportId] itself, and that where it went
  /// knows it as [remoteId] — for an app that uploads reports its own way,
  /// from [reports], rather than giving [Crashpad.start] a
  /// [CrashpadOptions.upload]. The report then reads as [CrashReport.uploaded]
  /// with that [CrashReport.remoteId], and nothing of this package sends it
  /// again.
  ///
  /// Works whatever state the report is in, so a report held back for consent
  /// can be sent and recorded without [requestUpload] first. Throws
  /// [CrashpadErrorCode.reportNotFound] for a report that is not there or is
  /// already recorded as uploaded.
  ///
  /// On desktop, a handler started *with* an upload URL may send a report
  /// between the app reading it and this call; an app uploading its own way
  /// gives it none.
  Future<void> recordUpload(String reportId, {required String remoteId}) async {
    final path = directory.path;
    try {
      await Isolate.run(() => recordOwnUpload(path, reportId, remoteId));
    } on CrashpadNotFound {
      throw CrashpadException(
        CrashpadErrorCode.reportNotFound,
        'no report $reportId that is not already uploaded',
      );
    }
  }

  /// Deletes a report, its minidump and its attachments.
  void delete(String reportId) {
    callNative((arena, error) {
      return (
        nativeDatabaseDeleteReport(
          _path(arena),
          reportId.toNativeUtf8(allocator: arena),
          error,
        ),
        null,
      );
    });
    forgetReport(directory.path, reportId);
  }

  static List<File> _attachments(String database, String id) {
    final directory = Directory('$database/attachments/$id');
    if (!directory.existsSync()) return const [];
    return directory.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  Pointer<Utf8> _path(Arena arena) =>
      directory.path.toNativeUtf8(allocator: arena);
}
