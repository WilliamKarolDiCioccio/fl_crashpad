// Real crashes, real reports: each test runs test/crasher in its own process —
// Crashpad cannot be started twice, and the crash is the point — and then
// reads the database it wrote to.
@TestOn('linux || mac-os || windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_crashpad/fl_crashpad.dart';
import 'package:test/test.dart';

import 'support/artifacts.dart';

void main() {
  final handler = hostArtifacts().handler!;
  late Directory build;
  late File crasher;
  late Directory temp;

  setUpAll(() async {
    // Built once, AOT, into a bundle with its own copy of the library; see the
    // header of test/crasher/bin/crasher.dart for why not `dart run`.
    build = Directory.systemTemp.createTempSync('fl_crashpad_crasher_');
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

  setUp(() => temp = Directory.systemTemp.createTempSync('fl_crashpad_'));
  // Windows refuses to delete a directory a process still has a file open in,
  // and a handler lets go of its database only once it notices its last
  // client has gone — a moment after the client itself.
  tearDown(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        temp.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  Future<ProcessResult> runCrasher(String kind) =>
      Process.run(crasher.path, [temp.path, handler.path, kind]);

  // What must not survive sanitising, in both encodings a minidump uses.
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']!;
  List<int> utf16(String s) => [
    for (final unit in s.codeUnits) ...[unit & 0xff, unit >> 8],
  ];
  bool holds(List<int> haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var k = 0; k < needle.length; k++) {
        if (haystack[i + k] != needle[k]) continue outer;
      }
      return true;
    }
    return false;
  }

  bool leaks(List<int> bytes) =>
      holds(bytes, utf8.encode(home)) ||
      holds(bytes, utf16(home)) ||
      holds(bytes, utf8.encode('ada@example.com'));

  /// The raw minidump, straight off the disk, before anything of ours reads
  /// it. Waits for the handler, which writes it after the child is gone.
  Future<List<int>> rawDump() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      // Crashpad's generic database files a report by state; the Windows one
      // keeps every report in reports/ and the state in its metadata file.
      for (final state in ['pending', 'completed', 'reports']) {
        final directory = Directory('${temp.path}/$state');
        if (!directory.existsSync()) continue;
        for (final file in directory.listSync().whereType<File>()) {
          if (file.path.endsWith('.dmp')) return file.readAsBytesSync();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no minidump appeared in ${temp.path}');
  }

  Future<CrashReport> onlyReport() async {
    final reports = await CrashReportDatabase(temp).reports();
    expect(reports, hasLength(1));
    return reports.single;
  }

  Future<void> expectSanitisedReport(String kind) async {
    // The test is only worth something if there was something to remove.
    expect(
      leaks(await rawDump()),
      isTrue,
      reason: 'the raw dump should hold the home directory and the email',
    );
    final report = await onlyReport();
    expect(report.sanitized, isTrue);
    final bytes = report.minidump.readAsBytesSync();
    expect(
      leaks(bytes),
      isFalse,
      reason: 'sanitised before it was handed over',
    );
    // Crashpad keeps annotations as plain UTF-8 inside the minidump, so the
    // bytes are enough to know both kinds travelled — and survived cleaning.
    final text = latin1.decode(bytes);
    expect(text, contains('runtime-$kind'), reason: 'runtime annotation');
    expect(text, contains('process-$kind'), reason: 'process annotation');
  }

  for (final kind in CrashpadTestCrash.values) {
    // macOS catches a stack overflow as a Mach EXC_BAD_ACCESS on the guard
    // page, but cannot read the exhausted thread to write the dump; instead of
    // terminating it resumes the thread, which re-faults forever. So a stack
    // overflow on a native thread is not captured on macOS — see the README's
    // macOS notes — and asserting it here would hang. Every other crash, and
    // every kind on Linux and Windows, is caught.
    final unsupported =
        Platform.isMacOS && kind == CrashpadTestCrash.stackOverflowOnThread;
    test(
      '${kind.name} leaves a sanitised report with both annotations',
      () async {
        final result = await runCrasher(kind.name);
        expect(result.exitCode, isNot(0), reason: '${result.stderr}');
        await expectSanitisedReport(kind.name);
      },
      skip: unsupported
          ? 'macOS does not capture a stack overflow on a native thread'
          : null,
    );
  }

  test('a fast-fail crash is reported through WER, now that start lists the '
      'module in the registry itself', () async {
    // crashpad_wer.dll beside the crasher, which is where an app has it.
    final module = File('${crasher.parent.path}\\crashpad_wer.dll');
    File('${handler.parent.path}\\crashpad_wer.dll').copySync(module.path);
    const key =
        r'HKCU\Software\Microsoft\Windows\Windows Error Reporting'
        r'\RuntimeExceptionHelperModules';
    // Named by the path start resolved, which may spell the temp folder
    // differently from Directory.systemTemp (a short 8.3 name on a runner),
    // so the value is found by the build folder's unique name.
    final folder = build.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    Future<List<String>> ours() async {
      final listed = await Process.run('reg', ['query', key]);
      return [
        for (final line in '${listed.stdout}'.split('\n'))
          if (line.contains(folder) && line.contains('REG_DWORD'))
            line.substring(0, line.indexOf('REG_DWORD')).trim(),
      ];
    }

    addTearDown(() async {
      for (final name in await ours()) {
        await Process.run('reg', ['delete', key, '/v', name, '/f']);
      }
    });

    final result = await runCrasher('fastfail');
    expect(result.exitCode, isNot(0), reason: '${result.stderr}');
    expect(await ours(), [
      endsWith(r'\crashpad_wer.dll'),
    ], reason: 'start listed the module under HKCU');
    await expectSanitisedReport('fastfail');
  }, skip: Platform.isWindows ? null : 'fast-fail and WER are Windows only');

  test('dumpWithoutCrash leaves a report and the process carries on', () async {
    final result = await runCrasher('dump');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    await expectSanitisedReport('dump');
  });

  test(
    'only the sanitised report is sent, and only on the next start',
    () async {
      final uploads = <List<int>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        uploads.add(
          request.headers.value('content-encoding') == 'gzip'
              ? gzip.decode(body)
              : body,
        );
        request.response.write('report-1');
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/upload';

      // Consent is on and there is a URL, and still the dying process sends
      // nothing: nothing of ours could have cleaned the report yet.
      final crash = await Process.run(crasher.path, [
        temp.path,
        handler.path,
        'segfault',
        url,
      ]);
      expect(crash.exitCode, isNot(0), reason: '${crash.stderr}');
      expect(leaks(await rawDump()), isTrue);
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(uploads, isEmpty, reason: 'sent from the crashed process');

      // The next start cleans it, then asks for it; the handler it launches
      // sends it on its first pass.
      final next = await Process.start(crasher.path, [
        temp.path,
        handler.path,
        'wait',
        url,
      ]);
      addTearDown(() async {
        next.kill();
        await next.exitCode;
      });
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (uploads.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(uploads, hasLength(1), reason: 'sent on the next start');

      final body = uploads.single;
      expect(latin1.decode(body), contains('upload_file_minidump'));
      expect(latin1.decode(body), contains('runtime-segfault'));
      expect(leaks(body), isFalse, reason: 'what left the machine was clean');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
