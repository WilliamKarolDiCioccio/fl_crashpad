// The sanitiser: the log redactor's rules, proved to be the same rules, and
// the same rules applied to a minidump without moving a byte.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_crashpad/fl_crashpad.dart';
import 'package:fl_crashpad/src/sanitizer.dart' show sanitizeReportFiles;
import 'package:test/test.dart';

void main() {
  group('the log redactor\'s contract', () {
    // test/fixtures/redaction.json is ripple_telemetry's fixture, copied
    // verbatim so that a diff against the original is empty: the rules were
    // copied, and this is what keeps that true. The one deliberate difference
    // is the token: a project root there is a sensitive root here, and a
    // general-purpose package says `<private>`, not `<project>`.
    final fixture =
        jsonDecode(File('test/fixtures/redaction.json').readAsStringSync())
            as Map<String, Object?>;
    final sanitizers = {
      for (final MapEntry(key: name, value: raw)
          in (fixture['environments']! as Map<String, Object?>).entries)
        name: () {
          final e = raw! as Map<String, Object?>;
          return ReportSanitizer(
            home: e['home'] as String?,
            userName: e['userName'] as String?,
            exemptRoots: (e['exemptRoots']! as List).cast<String>(),
            sensitiveRoots: (e['projectRoots']! as List).cast<String>(),
            windows: e['windows']! as bool,
          );
        }(),
    };

    for (final one
        in (fixture['cases']! as List).cast<Map<String, Object?>>()) {
      test('${one['name']} [${one['environment']}]', () {
        final sanitizer = sanitizers[one['environment']]!;
        expect(
          sanitizer.sanitizeText(one['in']! as String),
          (one['out']! as String).replaceAll('<project>', '<private>'),
          reason: one['why'] as String?,
        );
      });
    }
  });

  group('what a crash report adds', () {
    final sanitizer = ReportSanitizer(
      home: '/home/ada',
      userName: 'ada',
      exemptRoots: ['/opt/app'],
      secrets: ['LICENCE-7F3A-99'],
    );

    test('an environment variable that names a secret loses its value', () {
      // `\b` cannot find TOKEN inside GITHUB_TOKEN, so the log rules miss
      // every conventional variable name; a minidump holds the environment.
      expect(
        sanitizer.sanitizeText('AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG'),
        'AWS_SECRET_ACCESS_KEY=<redacted>',
      );
      expect(
        sanitizer.sanitizeText('SESSION_COOKIE=abc123def456'),
        'SESSION_COOKIE=<redacted>',
      );
      expect(
        sanitizer.sanitizeText('XDG_SESSION_TYPE=wayland'),
        'XDG_SESSION_TYPE=<redacted>',
        reason: 'over-matching a name is the safe direction',
      );
      expect(sanitizer.sanitizeText('LANG=en_GB.UTF-8'), 'LANG=en_GB.UTF-8');
    });

    test('a secret the app names is masked wherever it appears', () {
      expect(
        sanitizer.sanitizeText('licence LICENCE-7F3A-99 accepted'),
        'licence <secret> accepted',
      );
    });
    test('an Android library versioned with an @ is not an email', () {
      // Found in the first Android report: every HIDL library in the module
      // list had become <email>***, and its name is what symbols are found by.
      expect(
        sanitizer.sanitizeText(
          '/system/lib64/android.hardware.camera.device@3.2.so',
        ),
        '<path>/android.hardware.camera.device@3.2.so',
      );
      expect(
        sanitizer.sanitizeText('write to ada@example.so please'),
        'write to <email> please',
        reason: 'a domain that ends in .so is still a domain',
      );
    });
  });

  group('in a minidump', () {
    final sanitizer = ReportSanitizer(
      home: '/home/ada',
      userName: 'ada',
      exemptRoots: ['/opt/app'],
    );

    Uint8List utf16(String s) => Uint8List.fromList([
      for (final unit in s.codeUnits) ...[unit & 0xff, unit >> 8],
    ]);

    // A made-up dump: binary on either side of every run, as a real one has.
    final binary = [0x00, 0xff, 0x13, 0x80, 0x00];
    final original = Uint8List.fromList([
      ...binary,
      ...utf8.encode('HOME=/home/ada'),
      0,
      ...utf8.encode('GITHUB_TOKEN=ghp_abcdefghijklmnop1234'),
      0,
      ...utf8.encode('/opt/app/lib/libapp.so'),
      0,
      ...utf8.encode('/srv/builds/agent-7/obj/libengine.so'),
      ...binary,
      ...utf16(r'C:\Users\ada\AppData\Local\app\crash.log'),
      0,
      0,
      ...utf16('ada@example.com'),
      ...binary,
    ]);

    late Uint8List dump;
    late int masked;
    setUp(() {
      dump = Uint8List.fromList(original);
      masked = sanitizer.sanitizeBytes(dump);
    });

    String asUtf8() => latin1.decode(dump);
    String asUtf16() => String.fromCharCodes([
      for (var i = 0; i + 1 < dump.length; i += 2) dump[i] | (dump[i + 1] << 8),
    ]);
    String asUtf16Odd() => String.fromCharCodes([
      for (var i = 1; i + 1 < dump.length; i += 2) dump[i] | (dump[i + 1] << 8),
    ]);

    test('nothing moves: same length, and binary untouched', () {
      expect(dump.length, original.length);
      expect(masked, greaterThan(0));
      expect(dump.sublist(0, binary.length), binary);
      expect(dump.sublist(dump.length - binary.length), binary);
    });

    test('the secrets are gone in both encodings', () {
      final text = '${asUtf8()}\n${asUtf16()}\n${asUtf16Odd()}';
      expect(text, isNot(contains('/home/ada')));
      expect(text, isNot(contains('ghp_abcdefghijklmnop1234')));
      expect(text, isNot(contains(r'Users\ada')));
      expect(text, isNot(contains('ada@example.com')));
      expect(text, isNot(contains('agent-7')));
    });

    test('what a crash server needs is kept', () {
      final text = '${asUtf8()}\n${asUtf16()}\n${asUtf16Odd()}';
      expect(
        text,
        contains('/opt/app/lib/libapp.so'),
        reason: 'the app\'s own install directory is exempt',
      );
      expect(
        text,
        contains('/libengine.so'),
        reason: 'a path keeps its basename: it is how symbols are found',
      );
      expect(text, contains('HOME=<home>***'));
      expect(text, contains('GITHUB_TOKEN=<redacted>'));
      expect(text, contains('crash.log'));
    });
  });

  test('a file is sanitised in place, keeping its identity', () {
    final temp = Directory.systemTemp.createTempSync('fl_crashpad_sanitize_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final dump = File('${temp.path}/r.dmp')
      ..writeAsBytesSync([0, 1, ...utf8.encode('HOME=/home/ada'), 0, 2]);
    final attachments = Directory('${temp.path}/attachments')..createSync();
    final log = File('${attachments.path}/app.log')
      ..writeAsStringSync('opened /home/ada/notes.txt for ada@example.com\n');
    final before = dump.statSync();

    final masked = sanitizeReportFiles(
      ReportSanitizer(home: '/home/ada', userName: 'ada'),
      dump,
      attachments: attachments,
    );

    expect(masked, greaterThan(0));
    expect(dump.lengthSync(), before.size);
    expect(latin1.decode(dump.readAsBytesSync()), contains('HOME=<home>***'));
    expect(
      log.readAsStringSync(),
      'opened ~/notes.txt for <email>\n',
      reason: 'a text attachment gets the log redactor\'s exact output',
    );
  });
}
