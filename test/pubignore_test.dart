// 1.0.0 was published without lib/src/build/native_artifacts.dart: the
// .pubignore said `build/` where the .gitignore said `/build/`, and an
// unanchored pattern matches a directory of that name at any depth. Nothing
// failed — `pub publish --dry-run` reports a missing import as nothing at
// all — and every consumer's build hook broke on pub.dev's copy.
//
// Pub reads a .pubignore with .gitignore's rules, so git can answer which
// files it keeps out: the .pubignore is installed as the .gitignore of an
// empty repository and the tracked paths are asked about there, where no
// other ignore file can be consulted.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the .pubignore keeps nothing out of lib/, hook/ or bin/', () async {
    final tracked = await Process.run('git', [
      'ls-files',
      '--',
      'lib',
      'hook',
      'bin',
    ]);
    expect(tracked.exitCode, 0, reason: '${tracked.stderr}');
    final paths = (tracked.stdout as String).trim();
    expect(paths, contains('lib/src/build/'));

    final scratch = await Directory.systemTemp.createTemp('pubignore');
    addTearDown(() => scratch.delete(recursive: true));
    await Process.run('git', ['init', '-q'], workingDirectory: scratch.path);
    await File('.pubignore').copy('${scratch.path}/.gitignore');

    final process = await Process.start('git', [
      'check-ignore',
      '--no-index',
      '--stdin',
    ], workingDirectory: scratch.path);
    process.stdin.writeln(paths);
    await process.stdin.close();
    final ignored = await process.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    // 1 is git's "nothing matched", which is the answer this test wants.
    expect(await process.exitCode, anyOf(0, 1));
    expect(ignored.trim(), isEmpty, reason: 'excluded from the archive');
  });
}
