// The Android end-to-end check: real crashes of the example app on a device or
// emulator, the reports they leave, sanitised, and sent.
//
//   dart run tool/android_e2e.dart            # the one device adb sees
//
// Not part of `dart test`, which cannot reach a device. It needs `flutter` and
// `adb` (or ANDROID_HOME), a booted Android 10+ device, and the native half
// for its ABI in the cache (`dart run tool/build_native.dart --target
// android-x64 --install` for the emulator).
//
// What it proves, in order:
//   1. each CrashpadTestCrash, and a dump without a crash, leaves a report,
//      with the handler started by the system linker from inside the APK;
//   2. the raw report holds both kinds of annotation, and a crash's the
//      planted email — read as it appears, before a later launch sanitises it;
//   3. on the next launch every report is sanitised — the email gone from the
//      file itself — and, with consent and a URL, sent: to a server on this
//      machine, reached from the emulator as 10.0.2.2, which must receive the
//      minidump and never the email;
//   4. the database then records each as uploaded, with the server's answer.
//
// The example is built in debug mode: `run-as`, which reads the app's files,
// works only for a debuggable app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _package = 'dev.wilielmus.fl_crashpad_example';
const _database = 'files/crashpad';
const _crashes = ['segfault', 'abort', 'stackOverflowOnThread', 'dump'];

Future<void> main() async {
  final root = Directory.fromUri(Platform.script.resolve('..'));
  final example = '${root.path}example';
  final adb = _adb();

  final abi = (await _capture(adb, [
    'shell',
    'getprop',
    'ro.product.cpu.abi',
  ])).trim();
  final platform = switch (abi) {
    'x86_64' => 'android-x64',
    'arm64-v8a' => 'android-arm64',
    _ => throw StateError('no fl_crashpad build for a $abi device'),
  };
  _step('device: $abi');

  await _run('flutter', [
    'build',
    'apk',
    '--debug',
    '--target-platform',
    platform,
  ], workingDirectory: example);
  await _run(adb, [
    'install',
    '-r',
    '$example/build/app/outputs/flutter-apk/app-debug.apk',
  ]);
  await _run(adb, ['shell', 'pm', 'clear', _package]);

  // Awake and unlocked, and kept so. An idle emulator's screen goes off, its
  // activity stops, and Android then cuts a background app's network — the
  // upload fails with ECONNABORTED, which reads like a firewall and is not.
  await _run(adb, ['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
  await _run(adb, ['shell', 'wm', 'dismiss-keyguard']);
  await _run(adb, ['shell', 'svc', 'power', 'stayon', 'true']);

  // 1. One report per crash, and 2. what it leaves, before anything of ours
  // has read it.
  //
  // Each report is read the moment it appears, because every launch
  // sanitises the reports already there, on the backlog isolate, and a
  // launch that lives — `dump` does not crash — gets as far as doing it: read
  // at the end, the earlier reports were already clean. The same launch may
  // reach its own dump, which it writes just after `start`, so the email is
  // required only of the three that die at once. They are what makes step 3's
  // "no longer holds the email" mean something.
  final seen = <String>{};
  for (final (index, kind) in _crashes.indexed) {
    await _launch(adb, ['--crash=$kind']);
    await _until('a report of $kind', () async {
      return (await _dumps(adb)).length == index + 1;
    });
    final dump = (await _dumps(adb)).toSet().difference(seen).single;
    seen.add(dump);
    final raw = await _pull(adb, dump);
    _expect(raw.contains('example.screen'), '$kind has the runtime annotation');
    _expect(raw.contains('example.build'), '$kind has the process annotation');
    if (kind != 'dump') {
      _expect(raw.contains('ada@example.com'), '$kind holds the planted email');
    }
    _step('$kind: report written, with both annotations');
  }
  _step('the crashes\' raw reports hold the planted email');

  // 3. The next launch sanitises and sends.
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  final received = <List<int>>[];
  server.listen((request) async {
    final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
    received.add(
      request.headers.value('content-encoding') == 'gzip'
          ? gzip.decode(body)
          : body,
    );
    request.response.write('e2e-${received.length}');
    await request.response.close();
  });
  final List<Map<String, Object?>> reports;
  try {
    reports = await _reportJson(adb, [
      '--report-json',
      '--upload=http://10.0.2.2:${server.port}/submit',
    ]);
  } finally {
    await server.close(force: true);
  }

  _expect(reports.length == _crashes.length, 'one report per crash');
  for (final report in reports) {
    _expect(report['sanitized'] == true, '${report['id']} is sanitised');
    _expect(report['uploaded'] == true, '${report['id']} is recorded sent');
    _expect(
      '${report['remoteId']}'.startsWith('e2e-'),
      '${report['id']} keeps the server\'s answer',
    );
    final file = await _pull(adb, '${report['minidump']}');
    _expect(
      !file.contains('ada@example.com'),
      '${report['id']} no longer holds the email on disk',
    );
  }
  _expect(received.length == _crashes.length, 'every report was received');
  for (final body in received) {
    final text = latin1.decode(body);
    _expect(text.contains('upload_file_minidump'), 'a minidump was sent');
    _expect(text.contains('example.screen'), 'annotations were sent');
    _expect(!text.contains('ada@example.com'), 'no email left the device');
  }
  _step('sanitised, sent to this machine, and recorded as uploaded');
  stdout.writeln('\nandroid e2e: all good');
}

/// Starts the example afresh with [args], in a new task.
///
/// Both halves matter. A crashed app is still being torn down — its
/// tombstone written — for a while after its report exists, and an
/// `am start` in that window starts nothing. And without clearing the task,
/// Android may recreate the activity from the task's *first* intent, so the
/// app runs with the arguments of some earlier launch.
Future<void> _launch(String adb, List<String> args) async {
  await _until('the last run to end', () async {
    final pid = await Process.run(adb, ['shell', 'pidof', _package]);
    return '${pid.stdout}'.trim().isEmpty;
  });
  await _start(adb, args);
}

Future<void> _start(String adb, List<String> args) => _run(adb, [
  'shell',
  'am',
  'start',
  '-S',
  '-W',
  // FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TASK
  '-f',
  '0x10008000',
  '-n',
  '$_package/.MainActivity',
  '--esal',
  'dart_entrypoint_args',
  args.join(','),
]);

/// Launches with [args] and returns what the example printed for
/// `--report-json`.
Future<List<Map<String, Object?>>> _reportJson(
  String adb,
  List<String> args,
) async {
  await _run(adb, ['logcat', '-c']);
  await _launch(adb, args);
  List<Map<String, Object?>>? reports;
  await _until('the report list', () async {
    final log = await _capture(adb, ['logcat', '-d', '-s', 'flutter']);
    for (final line in LineSplitter.split(log)) {
      if (line.contains('fl_crashpad_error: ')) {
        throw StateError(line.split('fl_crashpad_error: ').last);
      }
      const marker = 'fl_crashpad_reports: ';
      final at = line.indexOf(marker);
      if (at < 0) continue;
      reports = (jsonDecode(line.substring(at + marker.length)) as List)
          .cast<Map<String, Object?>>();
      return true;
    }
    return false;
  });
  return reports!;
}

Future<List<String>> _dumps(String adb) async {
  // One string: adb joins its arguments into a single remote command line,
  // so a quoted `sh -c` has to arrive already quoted.
  final listing = await Process.run(adb, [
    'shell',
    "run-as $_package sh -c 'ls $_database/pending/*.dmp "
        "$_database/completed/*.dmp 2>/dev/null'",
  ]);
  return LineSplitter.split(
    '${listing.stdout}',
  ).where((l) => l.endsWith('.dmp')).toList();
}

/// A file of the app's, as Latin-1 so that every byte survives.
Future<String> _pull(String adb, String path) async {
  final result = await Process.run(adb, [
    'exec-out',
    'run-as',
    _package,
    'cat',
    path,
  ], stdoutEncoding: latin1);
  return result.stdout as String;
}

String _adb() {
  final environment = Platform.environment;
  for (final sdk in [
    environment['ANDROID_HOME'],
    environment['ANDROID_SDK_ROOT'],
    if (environment['HOME'] case final home?) '$home/Android/Sdk',
  ].nonNulls) {
    final adb = File('$sdk/platform-tools/adb');
    if (adb.existsSync()) return adb.path;
  }
  return 'adb';
}

Future<void> _until(String what, Future<bool> Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TimeoutException('waiting for $what');
}

void _expect(bool condition, String what) {
  if (!condition) throw StateError('expected: $what');
}

void _step(String what) => stdout.writeln('ok  $what');

Future<void> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
}

Future<String> _capture(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout as String;
}
