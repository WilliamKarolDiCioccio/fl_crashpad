import 'dart:io';

import 'package:fl_crashpad/fl_crashpad.dart';
import 'package:fl_crashpad_example/report_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/minidump_builder.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('fl_crashpad_page_'));
  tearDown(() => temp.deleteSync(recursive: true));

  testWidgets('a report opens on what happened and its annotations', (
    tester,
  ) async {
    final dump = File('${temp.path}/report.dmp')
      ..writeAsBytesSync(syntheticMinidump());
    final report = CrashReport(
      id: '03020100-0504-0706-0809-0a0b0c0d0e0f',
      state: CrashReportState.pending,
      createdAt: DateTime.utc(2026, 9, 29),
      uploaded: false,
      remoteId: null,
      uploadAttempts: 0,
      uploadExplicitlyRequested: false,
      minidump: dump,
    );
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: ReportPage(report: report, database: CrashReportDatabase(temp)),
      ),
    );
    // The dump is read on another isolate: let it finish, then draw.
    await tester.runAsync(() async {
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
      }
    });
    await tester.pump();

    expect(find.text('SIGSEGV'), findsOneWidget);
    expect(
      find.textContaining('libfl_crashpad_native.so + 0x1234'),
      findsOneWidget,
    );
    expect(find.text('version'), findsOneWidget, reason: 'process annotation');
    expect(find.text('editor'), findsOneWidget, reason: 'runtime annotation');
    expect(find.text('Crashed in libfl_crashpad_native.so'), findsOneWidget);
    expect(
      find.text('03020100-0504-0706-0809-0a0b0c0d0e0f.dmp'),
      findsOneWidget,
      reason: 'the upload names the file by its id, never its path',
    );
  });
}
