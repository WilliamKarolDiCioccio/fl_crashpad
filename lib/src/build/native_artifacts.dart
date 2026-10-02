// Where the native half of the package comes from: the lock, the targets, the
// per-user cache and the verified download that fills it.
//
// **Build-time only.** The hook, `bin/prefetch.dart` and `tool/build_native.dart`
// import this; nothing an application runs does. It is under `lib/` only so
// the hook can reach it as `package:fl_crashpad/src/build/...`.
//
// The cache is the one contract three independent consumers share — this
// file for the hook, `cmake/fetch_artifact.cmake` for Linux and Windows and
// `macos/Scripts/embed_handler.sh` for the pod — so its layout is spelled the
// same way in all three and changes in all three together:
//
//   <cache root>/<artifacts version>/<target>/
//     .complete                 written last; a directory without it is ignored
//     lib/<library>             the client, loaded by Dart
//     bin/crashpad_handler[.exe]
//     bin/crashpad_handler.rev  the Crashpad revision the handler was built from
//     manifest.json
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// One published build of the native half.
///
/// macOS and the iOS simulator are single universal builds: one download
/// serves every architecture, and the hook takes the slice it is asked for.
///
/// There is no 32-bit Android build: mini_chromium's toolchain definition
/// fails GN's unused-assignment check for `target_cpu="arm"`, and fixing that
/// means patching upstream, which this package never does. An app still
/// builds for armeabi-v7a; there it has no library, and
/// `Crashpad.isAvailable` says so.
///
/// The mobile targets carry no handler executable. Android runs the handler
/// out of the library itself, through the system linker and a trampoline
/// that is a second library; iOS handles crashes in process. Both travel
/// entirely as code assets.
enum NativeTarget {
  linuxX64('linux-x64', 'linux'),
  linuxArm64('linux-arm64', 'linux'),
  windowsX64('windows-x64', 'windows'),
  windowsArm64('windows-arm64', 'windows'),
  macosUniversal('macos-universal', 'macos'),
  androidArm64('android-arm64', 'android'),
  androidX64('android-x64', 'android'),
  iosArm64('ios-arm64', 'ios'),
  iosSimulator('ios-simulator', 'ios');

  const NativeTarget(this.id, this.os);

  /// The name in the lock, the archive and the cache path.
  final String id;

  /// The target OS, spelled as `code_assets` spells it.
  final String os;

  /// The target for an OS and architecture as `code_assets` names them
  /// (`linux`, `x64`), or null for a combination with no build. An iOS
  /// target also depends on which SDK is being built for.
  static NativeTarget? of(
    String os,
    String architecture, {
    bool simulator = false,
  }) => switch ((os, architecture)) {
    ('linux', 'x64') => linuxX64,
    ('linux', 'arm64') => linuxArm64,
    ('windows', 'x64') => windowsX64,
    ('windows', 'arm64') => windowsArm64,
    ('macos', 'x64' || 'arm64') => macosUniversal,
    ('android', 'arm64') => androidArm64,
    ('android', 'x64') => androidX64,
    ('ios', 'arm64' || 'x64') when simulator => iosSimulator,
    ('ios', 'arm64') => iosArm64,
    _ => null,
  };

  static NativeTarget byId(String id) => values.firstWhere(
    (t) => t.id == id,
    orElse: () => throw ArgumentError.value(id, 'id', 'no such target'),
  );

  bool get isMobile => os == 'android' || os == 'ios';

  /// Whether one build holds several architectures, merged with `lipo`.
  bool get isUniversal => this == macosUniversal || this == iosSimulator;

  /// The client library's file name inside `lib/`.
  String get libraryFileName => switch (os) {
    'linux' || 'android' => 'libfl_crashpad_native.so',
    'macos' || 'ios' => 'libfl_crashpad_native.dylib',
    _ => 'fl_crashpad_native.dll',
  };

  /// Android's handler trampoline inside `lib/`: an executable that
  /// `/system/bin/linker64` runs, named `.so` so that the app's build packages
  /// it with the native libraries. The name is upstream's, and the shim looks
  /// for it beside itself.
  static const trampolineFileName = 'libcrashpad_handler_trampoline.so';

  /// The handler's file name inside `bin/`, or null for a target without a
  /// handler executable.
  String? get handlerFileName => switch (os) {
    'windows' => 'crashpad_handler.exe',
    'linux' || 'macos' => 'crashpad_handler',
    _ => null,
  };

  /// Every file a usable build of this target has, relative to its directory.
  List<String> get requiredFiles => [
    'lib/$libraryFileName',
    if (os == 'android') 'lib/$trampolineFileName',
    if (handlerFileName case final handler?) 'bin/$handler',
  ];

  /// The archive a release publishes for this target.
  String archiveName(String artifactsVersion) =>
      'fl_crashpad-native-$artifactsVersion-$id.tar.gz';
}

/// `native/artifacts.lock.json`: what the native half is built from, and the
/// digest every published archive must match before anything reads it.
class ArtifactLock {
  ArtifactLock._(this.json);

  factory ArtifactLock.parse(String source) {
    final json = jsonDecode(source) as Map<String, Object?>;
    if (json['schema'] != 1) {
      throw FormatException(
        'artifacts.lock.json has schema ${json['schema']}; this build reads 1',
      );
    }
    return ArtifactLock._(json);
  }

  factory ArtifactLock.read(File file) =>
      ArtifactLock.parse(file.readAsStringSync());

  final Map<String, Object?> json;

  /// The version of the native build — the cache directory and the release tag.
  String get artifactsVersion => json['artifacts']! as String;

  String get crashpadRevision =>
      (json['crashpad']! as Map<String, Object?>)['revision']! as String;

  /// Where the archives of [artifactsVersion] are downloaded from.
  ///
  /// The lock spells the version once: `{artifacts}` in `baseUrl` stands for
  /// it, so the release tag in the URL cannot be left behind when the version
  /// is bumped. CMake and the pod read the URL already filled in.
  Uri get releaseBaseUrl => Uri.parse(
    ((json['release']! as Map<String, Object?>)['baseUrl']! as String)
        .replaceAll('{artifacts}', artifactsVersion),
  );

  /// The published digest for [target], or null before its first release.
  String? sha256Of(NativeTarget target) {
    final targets = json['targets']! as Map<String, Object?>;
    final entry = targets[target.id] as Map<String, Object?>?;
    return entry?['sha256'] as String?;
  }

  Uri archiveUrl(NativeTarget target) =>
      releaseBaseUrl.resolve(target.archiveName(artifactsVersion));

  /// The lock as `native/artifacts.lock.cmake`, for the plugin's CMake —
  /// which cannot be asked to parse JSON: `string(JSON)` needs CMake 3.19,
  /// and the Flutter runner templates promise only 3.13.
  String toCmake() {
    final buffer = StringBuffer()
      ..writeln(_generatedHeader('#'))
      ..writeln('set(FL_CRASHPAD_ARTIFACTS_VERSION "$artifactsVersion")')
      ..writeln('set(FL_CRASHPAD_CRASHPAD_REVISION "$crashpadRevision")')
      ..writeln('set(FL_CRASHPAD_RELEASE_BASE_URL "$releaseBaseUrl")');
    for (final target in NativeTarget.values) {
      final variable = target.id.replaceAll('-', '_');
      buffer.writeln(
        'set(FL_CRASHPAD_SHA256_$variable "${sha256Of(target) ?? ''}")',
      );
    }
    return buffer.toString();
  }

  /// The lock as `native/artifacts.lock.txt`, one `key value` pair a line,
  /// for the pod's shell script. A target with no published build has `-`.
  String toText() {
    final buffer = StringBuffer()
      ..writeln(_generatedHeader('#'))
      ..writeln('artifacts $artifactsVersion')
      ..writeln('crashpad $crashpadRevision')
      ..writeln('baseUrl $releaseBaseUrl');
    for (final target in NativeTarget.values) {
      buffer.writeln('${target.id} ${sha256Of(target) ?? '-'}');
    }
    return buffer.toString();
  }

  static String _generatedHeader(String comment) =>
      '$comment Generated from artifacts.lock.json by tool/update_lock.dart. '
      'Do not edit.';
}

/// The per-user cache root on a build machine running [os] — the *host*,
/// which for a mobile target is not the target's OS — from the only variables a build hook is
/// given — `HOME` and `USERPROFILE` (hooks_runner filters the rest), which is
/// why this does not honour `XDG_CACHE_HOME` or `LOCALAPPDATA`: a cache the
/// hook could not find would be a cache the hook re-downloads.
Directory artifactCacheRoot({
  required String os,
  required Map<String, String> environment,
}) {
  String need(String name) {
    final value = environment[name];
    if (value == null || value.isEmpty) {
      throw StateError('fl_crashpad: \$$name is not set, so there is no cache');
    }
    return value;
  }

  return switch (os) {
    'linux' => Directory('${need('HOME')}/.cache/fl_crashpad'),
    'macos' => Directory('${need('HOME')}/Library/Caches/fl_crashpad'),
    'windows' => Directory(
      '${need('USERPROFILE')}\\AppData\\Local\\fl_crashpad',
    ),
    _ => throw ArgumentError.value(os, 'os', 'no cache for this OS'),
  };
}

/// A directory laid out as the header of this file describes.
class ArtifactDirectory {
  ArtifactDirectory(this.directory, this.target);

  final Directory directory;
  final NativeTarget target;

  File get library => File('${directory.path}/lib/${target.libraryFileName}');

  /// The handler executable, or null for a mobile target, which has none.
  File? get handler => switch (target.handlerFileName) {
    final name? => File('${directory.path}/bin/$name'),
    null => null,
  };

  /// Android's trampoline, beside the library.
  File get trampoline =>
      File('${directory.path}/lib/${NativeTarget.trampolineFileName}');

  File get completeStamp => File('${directory.path}/.complete');

  /// Whether every file the target needs is present.
  bool get hasFiles => target.requiredFiles.every(
    (name) => File('${directory.path}/$name').existsSync(),
  );

  /// Whether this directory is usable: stamped, and with every file present.
  bool get isComplete => completeStamp.existsSync() && hasFiles;
}

/// Why the native half could not be found, worded for the person whose build
/// just failed.
class ArtifactUnavailable implements Exception {
  ArtifactUnavailable(this.message);
  final String message;
  @override
  String toString() => 'fl_crashpad: $message';
}

/// Finds the native half for a target: an explicit directory if one was
/// given, otherwise the cache, otherwise a download verified against the lock.
class ArtifactResolver {
  ArtifactResolver({required this.lock, required this.cacheRoot});

  final ArtifactLock lock;
  final Directory cacheRoot;

  ArtifactDirectory cached(NativeTarget target) => ArtifactDirectory(
    Directory('${cacheRoot.path}/${lock.artifactsVersion}/${target.id}'),
    target,
  );

  Future<ArtifactDirectory> resolve(
    NativeTarget target, {
    Directory? override,
  }) async {
    if (override != null) {
      final explicit = ArtifactDirectory(override, target);
      if (!explicit.hasFiles) {
        throw ArtifactUnavailable(
          'artifacts_dir ${override.path} does not have all of '
          '${target.requiredFiles.join(', ')}',
        );
      }
      return explicit;
    }

    final hit = cached(target);
    if (hit.isComplete) return hit;
    await download(target);
    return hit;
  }

  /// Downloads, verifies and unpacks [target]'s archive into the cache.
  ///
  /// Safe to run from several processes at once — the hook, CMake and the
  /// pod can all be fetching during one parallel build. Everything happens in
  /// a private directory beside the destination, and the destination appears
  /// by one `rename`; a loser of that race finds the winner's complete copy
  /// and discards its own.
  Future<void> download(NativeTarget target) async {
    final sha256Expected = lock.sha256Of(target);
    final url = lock.archiveUrl(target);
    if (sha256Expected == null) {
      throw ArtifactUnavailable(
        'no ${target.id} build of native ${lock.artifactsVersion} has been '
        'published yet, so there is nothing to download. Build it from source '
        'with `dart run tool/build_native.dart --install` in the fl_crashpad '
        'package, or point the `artifacts_dir` hook user-define at a directory '
        'holding ${target.requiredFiles.join(', ')}.',
      );
    }

    final destination = cached(target);
    destination.directory.parent.createSync(recursive: true);
    final staging = destination.directory.parent.createTempSync(
      '.${target.id}-',
    );
    try {
      final bytes = await _get(url);
      final actual = sha256.convert(bytes).toString();
      if (actual != sha256Expected) {
        throw ArtifactUnavailable(
          '$url has sha256 $actual, but the lock pins $sha256Expected. '
          'Nothing was unpacked.',
        );
      }
      await extractArchiveToDisk(
        TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes)),
        staging.path,
      );
      final unpacked = ArtifactDirectory(staging, target);
      if (!unpacked.hasFiles) {
        throw ArtifactUnavailable('$url does not have the expected layout');
      }
      if (unpacked.handler case final handler?) _makeExecutable(handler);
      unpacked.completeStamp.writeAsStringSync(sha256Expected);
      commit(staging, destination);
    } finally {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }

  /// Moves a fully written [staging] directory into place as [destination].
  /// Used by the download and by a from-source `--install` alike.
  static void commit(Directory staging, ArtifactDirectory destination) {
    if (destination.isComplete) return;
    if (destination.directory.existsSync()) {
      // Left by a process that died mid-way: no stamp, so nobody reads it.
      destination.directory.deleteSync(recursive: true);
    }
    try {
      staging.renameSync(destination.directory.path);
    } on FileSystemException {
      if (!destination.isComplete) rethrow;
    }
  }

  static Future<List<int>> _get(Uri url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw ArtifactUnavailable('GET $url answered ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);
      return builder.takeBytes();
    } on SocketException catch (e) {
      throw ArtifactUnavailable('could not reach $url: ${e.message}');
    } finally {
      client.close();
    }
  }

  static void _makeExecutable(File file) {
    if (Platform.isWindows) return;
    final result = Process.runSync('chmod', ['755', file.path]);
    if (result.exitCode != 0) {
      throw ArtifactUnavailable('chmod 755 ${file.path}: ${result.stderr}');
    }
  }
}
