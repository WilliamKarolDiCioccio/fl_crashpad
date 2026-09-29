import 'dart:typed_data';

import 'package:fl_crashpad_example/minidump.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/minidump_builder.dart';

void main() {
  test('reads what happened, where, and every annotation', () {
    final dump = Minidump.parse(syntheticMinidump());
    final exception = dump.exception!;

    expect(exception.describe(dump.system!.platform), 'SIGSEGV');
    expect(exception.threadId, 4242);
    expect(exception.address, 0, reason: 'the data address, not the code');
    expect(exception.instructionPointer, 0x7f0000001234);
    final module = dump.moduleAt(exception.instructionPointer!)!;
    expect(module.name, 'libfl_crashpad_native.so');
    expect(exception.instructionPointer! - module.base, 0x1234);

    expect(dump.system!.os, 'Linux');
    expect(dump.system!.cpu, 'x64');
    expect(dump.system!.version, '6.8.0-generic');
    expect(dump.threadCount, 3);

    final crashpad = dump.crashpad!;
    expect(crashpad.reportId, '03020100-0504-0706-0809-0a0b0c0d0e0f');
    expect(crashpad.processAnnotations, {'version': '1.0'});
    expect(crashpad.moduleAnnotations[0]!.simple, {'screen': 'editor'});
  });

  test('si_code is signed, as abort() leaves it', () {
    final dump = Minidump.parse(syntheticMinidump(signal: 6, siCode: -6));
    expect(dump.exception!.describe(MinidumpSystem.linux), 'SIGABRT');
    expect(dump.exception!.signedFlags, -6);
  });

  test('a truncated or foreign file is a FormatException', () {
    final whole = syntheticMinidump();
    expect(
      () => Minidump.parse(Uint8List.sublistView(whole, 0, 200)),
      throwsFormatException,
    );
    expect(
      () => Minidump.parse(Uint8List.fromList(List.filled(64, 7))),
      throwsFormatException,
    );
  });
}
