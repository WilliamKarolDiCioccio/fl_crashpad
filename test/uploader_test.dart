// The upload this package makes itself on Android and iOS, run here against
// real reports from test/crasher and a local server: the platforms it is for
// cannot run `dart test`, and nothing about it is platform-specific but which
// platforms call it.
@TestOn('linux || mac-os || windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_crashpad/fl_crashpad.dart';
import 'package:fl_crashpad/src/report_store.dart';
import 'package:fl_crashpad/src/uploader.dart';
import 'package:test/test.dart';

import 'support/artifacts.dart';

void main() {
  final handler = hostArtifacts().handler!;
  late Directory build;
  late File crasher;
  late Directory temp;
  late HttpServer server;
  late List<(Uri, HttpHeaders, List<int>)> received;
  late int status;

  setUpAll(() async {
    // As crash_test.dart builds it, and for the same reason: never `dart run`
    // a child of the test runner in this package.
    build = Directory.systemTemp.createTempSync('fl_crashpad_uploader_');
    for (final args in [
      ['pub', 'get'],
      ['build', 'cli', '--output', build.path],
    ]) {
      final result = await Process.run(
        Platform.resolvedExecutable,
        args,
        workingDirectory: 'test/crasher',
      );
      if (result.exitCode != 0) {
        fail('dart ${args.join(' ')}: ${result.stdout}${result.stderr}');
      }
    }
    crasher = File(
      '${build.path}/bundle/bin/crasher${Platform.isWindows ? '.exe' : ''}',
    );
  });
  tearDownAll(() => build.deleteSync(recursive: true));

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('fl_crashpad_');
    received = [];
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      received.add((request.uri, request.headers, body));
      request.response
        ..statusCode = status
        ..write('remote-7');
      await request.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  CrashpadUpload upload() =>
      CrashpadUpload(url: Uri.parse('http://127.0.0.1:${server.port}/submit'));

  /// A real report, parked unsent: the crasher is given no URL.
  Future<String> crash() async {
    final result = await Process.run(crasher.path, [
      temp.path,
      handler.path,
      'segfault',
    ]);
    expect(result.exitCode, isNot(0), reason: '${result.stderr}');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final reports = listNativeReports(temp.path);
      if (reports.isNotEmpty) return reports.single['id']! as String;
      await Future<void>.delayed(Duration.zero);
    }
    fail('no report was written');
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']!;
  bool leaks(List<int> body) {
    final text = latin1.decode(body);
    return text.contains(home) || text.contains('ada@example.com');
  }

  Future<CrashReport> stored(String id) async => (await CrashReportDatabase(
    temp,
  ).reports()).singleWhere((r) => r.id == id);

  test('a requested report is sent sanitised, as Crashpad would send it, '
      'and recorded as uploaded', () async {
    final id = await crash();
    sanitizeAndRequest(temp.path, ReportSanitizer.forHost(), id);

    await uploadPending(temp.path, upload());

    expect(received, hasLength(1));
    final (uri, headers, gzipped) = received.single;
    expect(headers.value('content-encoding'), 'gzip');
    // identifyClientViaUrl: the database's client id, from the minidump.
    expect(
      uri.queryParameters['guid'],
      matches(RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')),
    );
    final body = gzip.decode(gzipped);
    final text = latin1.decode(body);
    final boundary = headers.contentType!.parameters['boundary']!;
    expect(boundary, startsWith('---MultipartBoundary-'));
    expect(text, endsWith('--$boundary--\r\n'));
    // The fields Crashpad reads out of the minidump: both kinds of
    // annotation, each a part of its own.
    expect(
      text,
      contains(
        'Content-Disposition: form-data; name="fl_crashpad.process"\r\n\r\n'
        'process-segfault\r\n',
      ),
    );
    expect(
      text,
      contains('name="fl_crashpad.runtime"\r\n\r\nruntime-segfault'),
    );
    expect(
      text,
      contains(
        'name="upload_file_minidump"; filename="$id.dmp"\r\n'
        'Content-Type: application/octet-stream\r\n\r\nMDMP',
      ),
    );
    expect(leaks(body), isFalse, reason: 'what left the machine was clean');

    final report = await stored(id);
    expect(report.uploaded, isTrue);
    expect(report.remoteId, 'remote-7');
    expect(report.state, CrashReportState.completed);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'a report nobody has sanitised is never sent, even when requested',
    () async {
      final id = await crash();
      // Asked for behind the sanitiser's back.
      requestNativeUpload(temp.path, id);

      await uploadPending(temp.path, upload());

      expect(received, isEmpty);
      expect((await stored(id)).uploaded, isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a report held back is set aside unsent, and a refused one is kept '
      'for another try', () async {
    final held = await crash();
    processReports(temp.path, ReportSanitizer.forHost(), decide: true);
    await uploadPending(temp.path, upload());
    expect(received, isEmpty, reason: 'nobody agreed to send it');
    final set = listNativeReports(
      temp.path,
    ).singleWhere((r) => r['id'] == held);
    expect(set['state'], 'completed', reason: 'as the handler would');
    expect(set['uploaded'], isFalse);

    status = 500;
    CrashReportDatabase(temp).delete(held);
    final refused = await crash();
    sanitizeAndRequest(temp.path, ReportSanitizer.forHost(), refused);
    await uploadPending(temp.path, upload());
    expect(received, hasLength(1));
    final kept = listNativeReports(
      temp.path,
    ).singleWhere((r) => r['id'] == refused);
    expect(kept['state'], 'pending');
    expect(kept['uploadAttempts'], 1);
    expect(kept['uploaded'], isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
