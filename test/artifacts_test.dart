// The artifact cache and its download, against a local server: the path every
// user without a from-source build takes, and the one no release exists yet to
// exercise for real.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fl_crashpad/src/build/native_artifacts.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late HttpServer server;
  late List<int> archive;
  late int port;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('fl_crashpad_artifacts_');
    archive = _archive(NativeTarget.linuxX64);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((request) {
      request.response
        ..add(archive)
        ..close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  ArtifactResolver resolver({
    required String? sha256,
    NativeTarget target = NativeTarget.linuxX64,
  }) {
    final lock = ArtifactLock.parse(
      jsonEncode({
        'schema': 1,
        'artifacts': '9.9.9',
        'crashpad': {'url': 'x', 'revision': 'r'},
        'release': {'baseUrl': 'http://127.0.0.1:$port/'},
        'targets': {
          target.id: {'sha256': sha256},
        },
      }),
    );
    return ArtifactResolver(lock: lock, cacheRoot: temp);
  }

  test(
    'a verified download lands complete, with the handler executable',
    () async {
      final digest = sha256.convert(archive).toString();
      final result = await resolver(
        sha256: digest,
      ).resolve(NativeTarget.linuxX64);

      expect(result.isComplete, isTrue);
      expect(result.directory.path, '${temp.path}/9.9.9/linux-x64');
      if (!Platform.isWindows) {
        final mode = result.handler!.statSync().mode;
        expect(mode & 0x49, 0x49, reason: 'executable by everybody');
      }
      // Nothing left behind but the one directory.
      expect(Directory('${temp.path}/9.9.9').listSync().map((e) => e.path), [
        '${temp.path}/9.9.9/linux-x64',
      ]);
    },
  );

  test('a digest that does not match unpacks nothing', () async {
    await expectLater(
      resolver(sha256: 'f' * 64).resolve(NativeTarget.linuxX64),
      throwsA(
        isA<ArtifactUnavailable>().having(
          (e) => e.message,
          'message',
          contains('Nothing was unpacked'),
        ),
      ),
    );
    expect(Directory('${temp.path}/9.9.9').listSync(), isEmpty);
  });

  test('an unpublished target says how to build one instead', () async {
    await expectLater(
      resolver(sha256: null).resolve(NativeTarget.linuxX64),
      throwsA(
        isA<ArtifactUnavailable>().having(
          (e) => e.message,
          'message',
          contains('build_native.dart --install'),
        ),
      ),
    );
  });

  test('a cache hit is used without asking the server', () async {
    final digest = sha256.convert(archive).toString();
    await resolver(sha256: digest).resolve(NativeTarget.linuxX64);
    await server.close(force: true);
    final again = await resolver(sha256: digest).resolve(NativeTarget.linuxX64);
    expect(again.isComplete, isTrue);
  });

  test('targets are named the way code_assets names platforms', () {
    expect(NativeTarget.of('linux', 'x64'), NativeTarget.linuxX64);
    expect(NativeTarget.of('windows', 'arm64'), NativeTarget.windowsArm64);
    expect(NativeTarget.of('macos', 'x64'), NativeTarget.macosUniversal);
    expect(NativeTarget.of('macos', 'arm64'), NativeTarget.macosUniversal);
    expect(NativeTarget.of('android', 'arm64'), NativeTarget.androidArm64);
    expect(NativeTarget.of('android', 'x64'), NativeTarget.androidX64);
    expect(NativeTarget.of('android', 'arm'), isNull, reason: 'no 32-bit');
    expect(NativeTarget.of('ios', 'arm64'), NativeTarget.iosArm64);
    expect(
      NativeTarget.of('ios', 'arm64', simulator: true),
      NativeTarget.iosSimulator,
    );
    expect(
      NativeTarget.of('ios', 'x64', simulator: true),
      NativeTarget.iosSimulator,
    );
    expect(NativeTarget.of('ios', 'x64'), isNull, reason: 'no x64 devices');
  });

  test('an Android build without its trampoline is refused', () async {
    // The library alone would load, start, and lose every crash: the linker
    // would have nothing to run.
    archive = GZipEncoder().encode(
      TarEncoder().encode(
        Archive()
          ..add(ArchiveFile.bytes('lib/libfl_crashpad_native.so', [1, 2, 3])),
      ),
    );
    await expectLater(
      resolver(
        sha256: sha256.convert(archive).toString(),
        target: NativeTarget.androidX64,
      ).resolve(NativeTarget.androidX64),
      throwsA(
        isA<ArtifactUnavailable>().having(
          (e) => e.message,
          'message',
          contains('expected layout'),
        ),
      ),
    );
  });

  test('the lock names every target, and its three copies agree', () {
    final lock = ArtifactLock.read(File('native/artifacts.lock.json'));
    final targets = (lock.json['targets']! as Map).keys;
    expect(targets, unorderedEquals(NativeTarget.values.map((t) => t.id)));
    // CMake and the pod read these instead of the JSON; a digest recorded in
    // one and not the others would verify one half of a build and not the
    // other.
    expect(
      File('native/artifacts.lock.cmake').readAsStringSync(),
      lock.toCmake(),
      reason: 'run dart run tool/update_lock.dart',
    );
    expect(
      File('native/artifacts.lock.txt').readAsStringSync(),
      lock.toText(),
      reason: 'run dart run tool/update_lock.dart',
    );
  });
}

/// A small archive laid out as a release is, with made-up contents.
List<int> _archive(NativeTarget target) {
  final archive = Archive()
    ..add(ArchiveFile.bytes('lib/${target.libraryFileName}', [1, 2, 3]))
    ..add(
      ArchiveFile.bytes('bin/${target.handlerFileName}', [4, 5, 6])
        ..mode = 0x1ed, // 0755
    )
    ..add(ArchiveFile.string('bin/crashpad_handler.rev', 'r\n'));
  return GZipEncoder().encode(TarEncoder().encode(archive));
}
