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
// kind is a CrashpadTestCrash name; `fastfail` (Windows) ends the process
// with RaiseFailFastException, which skips the unhandled-exception filter and
// reaches Crashpad only through WER and crashpad_wer.dll; `dump` writes a
// report without a crash;
// `wait` starts Crashpad and stays alive until killed, so that a handler
// sending reports on start has a client to stay up for. With an upload URL,
// the user has consented.
import 'dart:ffi';
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
    case 'fastfail':
      // Straight from kernel32 rather than through the package: this is the
      // way a /GS failure or a Rust abort ends a process, and nothing of the
      // package's may stand between it and WER.
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      // Probe: the error mode, and SEM_NOGPFAULTERRORBOX (2) cleared, which
      // tells Windows not to invoke WER at all and is inherited.
      final getMode = kernel32
          .lookupFunction<Uint32 Function(), int Function()>('GetErrorMode');
      final setMode = kernel32
          .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
            'SetErrorMode',
          );
      final mode = getMode();
      stderr.writeln('error mode 0x${mode.toRadixString(16)}');
      if (Platform.environment['FL_CRASHPAD_CLEAR_NOGPFAULT'] == '1') {
        setMode(mode & ~2);
        stderr.writeln('error mode now 0x${getMode().toRadixString(16)}');
      }
      await stderr.flush();
      kernel32.lookupFunction<
        Void Function(Pointer<Void>, Pointer<Void>, Uint32),
        void Function(Pointer<Void>, Pointer<Void>, int)
      >('RaiseFailFastException')(nullptr, nullptr, 0);
    case 'wait':
      await Crashpad.sanitizationIdle;
      await Future<void>.delayed(const Duration(minutes: 5));
    default:
      Crashpad.crashForTesting(CrashpadTestCrash.values.byName(kind));
  }
}
