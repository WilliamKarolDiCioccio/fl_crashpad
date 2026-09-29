// The child process the crash tests run: starts Crashpad on the database it is
// given, annotates, and then ends however it was asked to.
//
//   crasher <database> <handler> <kind> [<upload url>]
//
// A package of its own, built with `dart build cli` by crash_test.dart, so that
// it carries its own copy of the native library. Run with `dart run` instead,
// it would re-run the build hook, which rewrites the library the test runner
// already has mapped — and a page not yet touched is then read back without
// its relocations, which crashes the runner, not the child.
//
// kind is a CrashpadTestCrash name; `dump` writes a report without a crash;
// `wait` starts Crashpad and stays alive until killed, so that a handler
// sending reports on start has a client to stay up for. With an upload URL,
// the user has consented.
import 'dart:io';

import 'package:fl_crashpad/fl_crashpad.dart';

Future<void> main(List<String> args) async {
  final [database, handler, kind, ...rest] = args;
  final url = rest.isEmpty ? null : Uri.parse(rest.single);
  Crashpad.annotations['fl_crashpad.runtime'] = 'runtime-$kind';
  // Something the sanitiser must take out, planted where an app might.
  Crashpad.annotations['fl_crashpad.contact'] = 'ada@example.com';
  Crashpad.start(
    CrashpadOptions(
      databaseDirectory: Directory(database),
      handler: File(handler),
      annotations: {'fl_crashpad.process': 'process-$kind'},
      upload: url == null ? null : CrashpadUpload(url: url, rateLimit: false),
      uploadsEnabled: url != null,
      periodicTasks: url != null,
    ),
  );
  switch (kind) {
    case 'dump':
      Crashpad.dumpWithoutCrash();
    case 'wait':
      await Crashpad.sanitizationIdle;
      await Future<void>.delayed(const Duration(minutes: 5));
    default:
      Crashpad.crashForTesting(CrashpadTestCrash.values.byName(kind));
  }
}
