// What this package keeps beside Crashpad's database, and the one routine
// every road to a report runs through.
//
//   <database>/fl_crashpad/settings.json          consent, and whether reports
//                                                 are sanitised
//   <database>/fl_crashpad/reports/<id>.json      one per report processed:
//                                                 the rules it was cleaned
//                                                 with, and what was decided
//
// **Why consent is ours and not Crashpad's.** Crashpad's handler uploads a
// report from its own process, straight after the crash, while the app is
// dead — nothing of ours can run in between. So while reports are sanitised,
// Crashpad's own "uploads enabled" setting is kept *off*: the handler parks
// every report unsent, and on the next start this package sanitises it and,
// if the user agreed, asks Crashpad to send it — explicitly, which Crashpad
// honours whatever its own setting says. The report that leaves is the
// cleaned one, and there is no window in which the raw one could.
//
// Each file carries an integer `version`. One from a newer build is read as
// "nothing known": for consent that means off, for a report it means
// unprocessed, and processing it again is harmless.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'ffi/bindings.dart';
import 'native_call.dart';
import 'sanitizer.dart';

const int _version = 1;

/// The package's own settings for one database.
class StoreSettings {
  const StoreSettings({required this.uploadConsent, required this.sanitize});

  final bool uploadConsent;
  final bool sanitize;

  static File _file(String database) =>
      File('$database/fl_crashpad/settings.json');

  static StoreSettings read(String database) {
    try {
      final json =
          jsonDecode(_file(database).readAsStringSync())
              as Map<String, Object?>;
      if (json['version'] != _version) {
        return const StoreSettings(uploadConsent: false, sanitize: true);
      }
      return StoreSettings(
        // The key predates the name: it is what 0.1 wrote, and renaming it
        // would quietly withdraw every consent already given.
        uploadConsent: json['uploadsEnabled'] == true,
        sanitize: json['sanitize'] != false,
      );
    } on Object {
      // Absent or unreadable: nobody has agreed to anything, and reports are
      // cleaned — the two defaults that cannot leak.
      return const StoreSettings(uploadConsent: false, sanitize: true);
    }
  }

  void write(String database) {
    _atomicWrite(_file(database), {
      'version': _version,
      'uploadsEnabled': uploadConsent,
      'sanitize': sanitize,
    });
  }

  /// Crashpad's own setting, which only ever says yes when nothing needs
  /// cleaning first.
  bool get crashpadUploadsEnabled => uploadConsent && !sanitize;
}

/// What happened to one report.
class _Marker {
  const _Marker({required this.rules, required this.masked, this.decision});

  final int rules;
  final int masked;

  /// `requested`, `held`, or null when no start has decided yet.
  final String? decision;

  static File file(String database, String id) =>
      File('$database/fl_crashpad/reports/$id.json');

  static _Marker? read(String database, String id) {
    try {
      final json =
          jsonDecode(file(database, id).readAsStringSync())
              as Map<String, Object?>;
      if (json['version'] != _version) return null;
      return _Marker(
        rules: json['rules']! as int,
        masked: json['masked']! as int,
        decision: json['decision'] as String?,
      );
    } on Object {
      return null;
    }
  }

  void write(String database, String id) => _atomicWrite(file(database, id), {
    'version': _version,
    'rules': rules,
    'masked': masked,
    'decision': ?decision,
  });
}

/// One report as the native side lists it, with what this package knows.
class StoredReport {
  StoredReport(this.json, {required this.sanitized});

  final Map<String, Object?> json;
  final bool sanitized;

  String get id => json['id']! as String;
  bool get uploaded => json['uploaded']! as bool;
  int get createdAt => json['createdAt']! as int;
}

/// Sanitises every report not yet sanitised — newest first — and, when
/// [decide] is set, asks Crashpad to send the ones the user agreed to.
///
/// Stops early once [budget] is spent and returns false; the rest is left for
/// the next call. A report whose files cannot be opened — the handler moving
/// it at that moment — is simply left for next time too.
///
/// Returns every report, each marked with whether it has been sanitised.
({List<StoredReport> reports, bool finished}) processReports(
  String database,
  ReportSanitizer sanitizer, {
  required bool decide,
  Duration? budget,
}) {
  final settings = StoreSettings.read(database);
  final clock = Stopwatch()..start();
  final listed = listNativeReports(
    database,
  )..sort((a, b) => (b['createdAt']! as int).compareTo(a['createdAt']! as int));
  var finished = true;
  final reports = <StoredReport>[];

  for (final json in listed) {
    final id = json['id']! as String;
    var marker = _Marker.read(database, id);
    if (marker == null && settings.sanitize) {
      if (budget != null && clock.elapsed > budget) {
        finished = false;
        reports.add(StoredReport(json, sanitized: false));
        continue;
      }
      try {
        final masked = sanitizeReportFiles(
          sanitizer,
          File(json['path']! as String),
          attachments: Directory('$database/attachments/$id'),
        );
        marker = _Marker(rules: ReportSanitizer.rulesVersion, masked: masked);
        marker.write(database, id);
      } on FileSystemException {
        finished = false;
        reports.add(StoredReport(json, sanitized: false));
        continue;
      }
    }

    if (decide &&
        settings.sanitize &&
        marker != null &&
        marker.decision == null &&
        json['uploaded'] != true) {
      final decision = settings.uploadConsent ? 'requested' : 'held';
      if (settings.uploadConsent) requestNativeUpload(database, id);
      marker = _Marker(
        rules: marker.rules,
        masked: marker.masked,
        decision: decision,
      )..write(database, id);
    }
    reports.add(StoredReport(json, sanitized: marker != null));
  }

  _forgetVanished(database, {for (final r in listed) r['id']! as String});
  return (reports: reports, finished: finished);
}

/// Sanitises one report if it is not already, then asks for its upload.
void sanitizeAndRequest(String database, ReportSanitizer sanitizer, String id) {
  final settings = StoreSettings.read(database);
  if (settings.sanitize && _Marker.read(database, id) == null) {
    final report = listNativeReports(database).firstWhere(
      (r) => r['id'] == id,
      orElse: () => throw CrashpadNotFound(id),
    );
    final masked = sanitizeReportFiles(
      sanitizer,
      File(report['path']! as String),
      attachments: Directory('$database/attachments/$id'),
    );
    _Marker(
      rules: ReportSanitizer.rulesVersion,
      masked: masked,
      decision: 'requested',
    ).write(database, id);
  }
  requestNativeUpload(database, id);
}

class CrashpadNotFound implements Exception {
  CrashpadNotFound(this.id);
  final String id;
}

/// Whether [id] has been through the sanitiser.
bool isSanitized(String database, String id) =>
    _Marker.read(database, id) != null;

void forgetReport(String database, String id) {
  final file = _Marker.file(database, id);
  if (file.existsSync()) file.deleteSync();
}

/// Markers of reports Crashpad has since pruned.
void _forgetVanished(String database, Set<String> present) {
  final directory = Directory('$database/fl_crashpad/reports');
  if (!directory.existsSync()) return;
  for (final file in directory.listSync().whereType<File>()) {
    final name = file.uri.pathSegments.last;
    if (!name.endsWith('.json')) continue;
    if (!present.contains(name.substring(0, name.length - 5))) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Somebody else got there first.
      }
    }
  }
}

List<Map<String, Object?>> listNativeReports(String database) {
  final json = callNative((arena, error) {
    final out = arena<Pointer<Utf8>>();
    final status = nativeDatabaseReports(
      database.toNativeUtf8(allocator: arena),
      out,
      error,
    );
    if (status != statusOk) return (status, '[]');
    try {
      return (status, out.value.toDartString());
    } finally {
      nativeFree(out.value.cast());
    }
  });
  return (jsonDecode(json) as List).cast<Map<String, Object?>>();
}

void requestNativeUpload(String database, String id) =>
    callNative((arena, error) {
      return (
        nativeDatabaseRequestUpload(
          database.toNativeUtf8(allocator: arena),
          id.toNativeUtf8(allocator: arena),
          error,
        ),
        null,
      );
    });

void setNativeUploadsEnabled(String database, bool enabled) =>
    callNative((arena, error) {
      return (
        nativeDatabaseSetUploadsEnabled(
          database.toNativeUtf8(allocator: arena),
          enabled,
          error,
        ),
        null,
      );
    });

/// Through a temporary file and a rename, so a torn write leaves the previous
/// answer standing rather than none.
void _atomicWrite(File file, Map<String, Object?> json) {
  file.parent.createSync(recursive: true);
  final temporary = File('${file.path}.tmp');
  temporary.writeAsStringSync('${jsonEncode(json)}\n', flush: true);
  temporary.renameSync(file.path);
}
