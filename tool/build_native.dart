// Builds the native half of fl_crashpad from source: Crashpad at the revision
// pinned in native/artifacts.lock.json, the handler, and the shim in native/.
//
//   dart run tool/build_native.dart                 # the host's target, archived
//   dart run tool/build_native.dart --install       # ...and put in the cache
//   dart run tool/build_native.dart --target linux-arm64
//   dart run tool/build_native.dart --target android-x64 --install
//
// The same script is what CI runs to produce a release, so a from-source build
// and a downloaded one are built identically. It needs git, python3 (GN runs
// mini_chromium's helpers with it) and the platform's compiler: clang on Linux
// and macOS, and on Windows either an installed LLVM or Visual Studio's MSVC.
// Android targets build on any of the three with an NDK; iOS targets on a Mac
// with Xcode.
// gn and ninja come from Chromium's package server at the pinned versions.
//
// Everything is written under build/native/, which is ignored by git and pub.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:fl_crashpad/src/build/native_artifacts.dart';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    stdout.writeln(_Options.usage);
    exitCode = 64;
    return;
  }

  final package = Directory.fromUri(Platform.script.resolve('..'));
  final lock = ArtifactLock.read(
    File('${package.path}native/artifacts.lock.json'),
  );
  final work = Directory('${package.path}build/native');
  final builder = _Builder(
    package: package,
    lock: lock,
    work: work,
    target: options.target,
    sysroot: options.sysroot,
    ndk: options.ndk,
    extraCflags: options.extraCflags,
    extraLdflags: options.extraLdflags,
    jobs: options.jobs,
  );

  final staged = await builder.build();
  final archive = await builder.archive(staged, options.outDirectory);
  final digest = sha256.convert(archive.readAsBytesSync()).toString();
  stdout
    ..writeln()
    ..writeln('archive  ${archive.path}')
    ..writeln('sha256   $digest');

  if (options.install) {
    final cacheRoot = artifactCacheRoot(
      os: Platform.operatingSystem,
      environment: Platform.environment,
    );
    final destination = ArtifactResolver(
      lock: lock,
      cacheRoot: cacheRoot,
    ).cached(options.target);
    builder.install(staged, destination);
    stdout.writeln('cache    ${destination.directory.path}');
  }
}

class _Options {
  _Options(
    this.target,
    this.install,
    this.sysroot,
    this.ndk,
    this.extraCflags,
    this.extraLdflags,
    this.jobs,
    this.outDirectory,
  );

  final NativeTarget target;
  final bool install;
  final String? sysroot;
  final String? ndk;
  final String? extraCflags;
  final String? extraLdflags;
  final int? jobs;
  final String? outDirectory;

  static const usage = '''
Usage: dart run tool/build_native.dart [options]

  --target <id>     linux-x64, linux-arm64, windows-x64, windows-arm64,
                    macos-universal, android-arm64, android-x64,
                    ios-arm64 or ios-simulator. Defaults to the host.
  --install         Put the result in the per-user artifact cache, where the
                    build hook, CMake and the pod look for it.
  --out <dir>       Where to write the archive (default build/native/dist).
  --sysroot <dir>   Linux: build against this sysroot instead of the host.
                    The glibc floor of a Linux build is whatever it is built
                    against, so a release is built on an old distribution.
  --ndk <dir>       Android: the NDK to build with. Defaults to
                    \$ANDROID_NDK_HOME, then the newest under
                    \$ANDROID_HOME/ndk or ~/Android/Sdk/ndk.
  --extra-cflags <flags>, --extra-ldflags <flags>
                    Appended to the compiler and linker flags, e.g. to point
                    at libcurl's headers on a machine without the -dev package.
  -j <n>            Parallel ninja jobs.''';

  static _Options? parse(List<String> arguments) {
    NativeTarget? target;
    var install = false;
    String? sysroot;
    String? ndk;
    String? extraCflags;
    String? extraLdflags;
    int? jobs;
    String? out;
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      String next() {
        if (i + 1 >= arguments.length) {
          throw ArgumentError('$argument needs a value');
        }
        return arguments[++i];
      }

      switch (argument) {
        case '--target':
          target = NativeTarget.byId(next());
        case '--install':
          install = true;
        case '--sysroot':
          sysroot = next();
        case '--ndk':
          ndk = next();
        case '--extra-cflags':
          extraCflags = next();
        case '--extra-ldflags':
          extraLdflags = next();
        case '--out':
          out = next();
        case '-j':
          jobs = int.parse(next());
        case '-h' || '--help':
          return null;
        default:
          stderr.writeln('unknown option $argument');
          return null;
      }
    }
    return _Options(
      target ?? _hostTarget(),
      install,
      sysroot,
      ndk,
      extraCflags,
      extraLdflags,
      jobs,
      out,
    );
  }
}

NativeTarget _hostTarget() => switch (Abi.current()) {
  Abi.linuxX64 => NativeTarget.linuxX64,
  Abi.linuxArm64 => NativeTarget.linuxArm64,
  Abi.windowsX64 => NativeTarget.windowsX64,
  Abi.windowsArm64 => NativeTarget.windowsArm64,
  Abi.macosX64 || Abi.macosArm64 => NativeTarget.macosUniversal,
  final abi => throw UnsupportedError('no fl_crashpad target for $abi'),
};

class _Builder {
  _Builder({
    required this.package,
    required this.lock,
    required this.work,
    required this.target,
    required this.sysroot,
    required this.ndk,
    required this.extraCflags,
    required this.extraLdflags,
    required this.jobs,
  });

  final Directory package;
  final ArtifactLock lock;
  final Directory work;
  final NativeTarget target;
  final String? sysroot;
  final String? ndk;
  final String? extraCflags;
  final String? extraLdflags;
  final int? jobs;

  Directory get crashpad => Directory('${work.path}/src/crashpad');

  /// What each architecture was configured with, recorded in manifest.json.
  final _gnArgsByCpu = <String, List<String>>{};

  Map<String, Object?> get _json => lock.json;

  /// Fetches, configures and builds; returns a directory laid out as the
  /// artifact cache expects (see native_artifacts.dart).
  Future<Directory> build() async {
    _checkHost();
    await _fetchSources();
    final gn = await _cipdTool(
      'gn/gn',
      'gn',
      (_json['tools']! as Map)['gn'] as String,
    );
    final ninja = await _cipdTool(
      'infra/3pp/tools/ninja',
      'ninja',
      (_json['tools']! as Map)['ninja'] as String,
    );
    _overlay();

    final cpus = target.isUniversal
        ? const ['arm64', 'x64']
        : [target.id.endsWith('arm64') ? 'arm64' : 'x64'];
    final outs = <Directory>[];
    for (final cpu in cpus) {
      final out = Directory('${work.path}/out/${target.id}-$cpu');
      final gnArgs = _gnArgs(cpu);
      _gnArgsByCpu[cpu] = gnArgs;
      await _run(gn.path, [
        'gen',
        out.path,
        '--root=${crashpad.path}',
        '--dotfile=${crashpad.path}/third_party/fl_crashpad/fl_crashpad.gn',
        '--args=${gnArgs.join(' ')}',
      ]);
      // The root target by name: GN also loads Crashpad's test targets from
      // the files it reads, and a bare `ninja` would try to build those too.
      await _run(ninja.path, [
        '-C',
        out.path,
        if (jobs != null) ...['-j', '$jobs'],
        'third_party/fl_crashpad:root',
      ]);
      outs.add(out);
    }
    return _stage(outs);
  }

  void _checkHost() {
    if (target.os == 'android') return;
    if (target.os == 'ios') {
      if (!Platform.isMacOS) {
        throw StateError('building ${target.id} needs a Mac with Xcode');
      }
      return;
    }
    final host = _hostTarget();
    final sameOs = host.os == target.os;
    if (!sameOs) {
      throw StateError(
        'building ${target.id} needs a ${target.os} host; this is ${host.id}',
      );
    }
    if (target.os == 'linux' && host != target) {
      throw StateError(
        'cross-building ${target.id} from ${host.id} is not supported; '
        'build on a ${target.id} machine',
      );
    }
  }

  // --------------------------------------------------------------------------
  // Sources

  Future<void> _fetchSources() async {
    final crashpadPin = _json['crashpad']! as Map<String, Object?>;
    await _checkout(
      crashpad,
      crashpadPin['url']! as String,
      crashpadPin['revision']! as String,
    );
    final dependencies = _json['dependencies']! as Map<String, Object?>;
    for (final MapEntry(key: path, value: pin) in dependencies.entries) {
      pin as Map<String, Object?>;
      if (!(pin['os']! as List).contains(target.os)) continue;
      await _checkout(
        Directory('${crashpad.path}/$path'),
        pin['url']! as String,
        pin['revision']! as String,
      );
    }
  }

  /// A shallow checkout of exactly [revision], reused when it is already there.
  Future<void> _checkout(
    Directory directory,
    String url,
    String revision,
  ) async {
    if (File('${directory.path}/.git/HEAD').existsSync()) {
      final head = await _capture('git', [
        '-C',
        directory.path,
        'rev-parse',
        'HEAD',
      ]);
      if (head.trim() == revision) return;
    } else {
      directory.createSync(recursive: true);
      await _run('git', ['-C', directory.path, 'init', '--quiet']);
    }
    stdout.writeln('fetch    $url @ ${revision.substring(0, 12)}');
    await _run('git', [
      '-C',
      directory.path,
      'fetch',
      '--quiet',
      '--depth',
      '1',
      url,
      revision,
    ]);
    await _run('git', [
      '-C',
      directory.path,
      'checkout',
      '--quiet',
      '--detach',
      'FETCH_HEAD',
    ]);
  }

  /// Copies native/ into the checkout as third_party/fl_crashpad — a copy on
  /// every build, never a patch to a Crashpad file.
  void _overlay() {
    final destination = Directory('${crashpad.path}/third_party/fl_crashpad');
    if (destination.existsSync()) destination.deleteSync(recursive: true);
    _copyTree(Directory('${package.path}native'), destination);
    // Crashpad's .gn names `python3`, which a Windows machine may only have
    // as `python`. The copy is ours to adjust; native/ is left as it is.
    if (Platform.isWindows &&
        Process.runSync('where', ['python3']).exitCode != 0) {
      final dotfile = File('${destination.path}/fl_crashpad.gn');
      dotfile.writeAsStringSync(
        dotfile.readAsStringSync().replaceFirst(
          'script_executable = "python3"',
          'script_executable = "python"',
        ),
      );
    }
  }

  // --------------------------------------------------------------------------
  // Tools

  /// A tool from chrome-infra-packages at a pinned version, cached per host.
  Future<File> _cipdTool(String package, String name, String version) async {
    final platform = switch (Abi.current()) {
      Abi.linuxX64 => 'linux-amd64',
      Abi.linuxArm64 => 'linux-arm64',
      Abi.macosX64 => 'mac-amd64',
      Abi.macosArm64 => 'mac-arm64',
      Abi.windowsX64 => 'windows-amd64',
      Abi.windowsArm64 => 'windows-arm64',
      final abi => throw UnsupportedError('no $name for $abi'),
    };
    final executable = Platform.isWindows ? '$name.exe' : name;
    final directory = Directory(
      '${work.path}/tools/$platform/$name-${_safe(version)}',
    );
    final file = File('${directory.path}/$executable');
    if (file.existsSync()) return file;

    final url = Uri.parse(
      'https://chrome-infra-packages.appspot.com/dl/$package/$platform/+/$version',
    );
    stdout.writeln('tool     $url');
    final bytes = await _download(url);
    final zip = ZipDecoder().decodeBytes(bytes);
    final entry = zip.files.firstWhere(
      (f) => f.name == executable || f.name.endsWith('/$executable'),
      orElse: () => throw StateError('$url has no $executable'),
    );
    directory.createSync(recursive: true);
    file.writeAsBytesSync(entry.content as List<int>);
    if (!Platform.isWindows) await _run('chmod', ['755', file.path]);
    return file;
  }

  // --------------------------------------------------------------------------
  // Configure

  List<String> _gnArgs(String cpu) {
    final cflags = [?extraCflags];
    final ldflags = [?extraLdflags];
    final args = [
      'is_debug=false',
      'target_cpu="$cpu"',
      'fl_crashpad_crashpad_revision="${lock.crashpadRevision}"',
    ];
    switch (target.os) {
      case 'linux':
        if (sysroot != null) args.add('target_sysroot="$sysroot"');
        // The library goes into other people's processes: it must not bring a
        // libstdc++ that has to match theirs.
        args.add('link_libstdcpp_statically=true');
      case 'macos':
        // Flutter's own floor. mini_chromium's default is 13.0.
        args.add('mac_deployment_target="10.15"');
      case 'android':
        args
          ..add('target_os="android"')
          ..add('android_ndk_root="${_androidNdk()}"')
          // The lowest Crashpad compiles for: it calls
          // __system_property_read_callback, new in 26. Flutter's minSdk is
          // 24, and on 24 and 25 the library does not load, which the Dart
          // side reports as unsupported rather than failing the app. The
          // handler itself needs Android 10 (29), which the shim checks at
          // start; building for 29 would refuse to load on 26 to 28 for no
          // gain, since the check says why.
          ..add('android_api_level=26');
        // The C++ runtime inside the library rather than beside it: an app
        // that ships its own libc++_shared.so must not have to match ours.
        // And 16 KB pages, which Google Play requires of every native library
        // (and which the emulator image this was tested on uses).
        ldflags.insertAll(0, [
          '-static-libstdc++',
          '-Wl,-z,max-page-size=16384',
        ]);
      case 'ios':
        args
          ..add('target_os="ios"')
          ..add(
            'target_environment="${target == NativeTarget.iosSimulator ? 'simulator' : 'device'}"',
          )
          // Flutter's own floor. mini_chromium's default is 14.0.
          ..add('ios_deployment_target="13.0"');
      case 'windows':
        // The shared CRT, so that Crashpad's SIGABRT handler is registered in
        // the same C runtime the app, the Flutter engine and any Rust in the
        // process call abort() through. With mini_chromium's default static
        // CRT it would sit in a private copy and see no abort but its own.
        cflags.insert(0, '/MD');
        final llvm = _windowsLlvm();
        if (llvm != null) {
          args.add('clang_path="${llvm.replaceAll(r'\', '/')}"');
        } else {
          args.add('mini_chromium_is_clang=false');
        }
    }
    if (cflags.isNotEmpty) args.add('extra_cflags="${cflags.join(' ')}"');
    if (ldflags.isNotEmpty) args.add('extra_ldflags="${ldflags.join(' ')}"');
    return args;
  }

  /// The NDK to build Android with: `--ndk`, `ANDROID_NDK_HOME`, or the
  /// newest one the SDK manager installed.
  String _androidNdk() {
    if (ndk case final explicit?) return Directory(explicit).absolute.path;
    final environment = Platform.environment;
    if (environment['ANDROID_NDK_HOME'] case final home? when home.isNotEmpty) {
      return home;
    }
    final sdks = [
      environment['ANDROID_HOME'],
      environment['ANDROID_SDK_ROOT'],
      if (environment['HOME'] case final home?) ...[
        '$home/Android/Sdk',
        '$home/Library/Android/sdk',
      ],
      if (environment['LOCALAPPDATA'] case final local?) '$local\\Android\\Sdk',
    ];
    for (final sdk in sdks.nonNulls) {
      final root = Directory('$sdk/ndk');
      if (!root.existsSync()) continue;
      final versions = root.listSync().whereType<Directory>().toList()
        ..sort((a, b) => _compareVersions(b.path, a.path));
      if (versions.isNotEmpty) return versions.first.path;
    }
    throw StateError(
      'no Android NDK found: pass --ndk, or set ANDROID_NDK_HOME, or install '
      'one with the SDK manager',
    );
  }

  static int _compareVersions(String a, String b) {
    List<int> parts(String path) => path
        .split(RegExp(r'[/\\]'))
        .last
        .split('.')
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final x = parts(a), y = parts(b);
    for (var i = 0; i < x.length && i < y.length; i++) {
      if (x[i] != y[i]) return x[i].compareTo(y[i]);
    }
    return x.length.compareTo(y.length);
  }

  /// A binary from the NDK's LLVM toolchain.
  String _ndkTool(String name) {
    final host = switch (Abi.current()) {
      Abi.macosX64 || Abi.macosArm64 => 'darwin-x86_64',
      Abi.windowsX64 || Abi.windowsArm64 => 'windows-x86_64',
      _ => 'linux-x86_64',
    };
    final suffix = Platform.isWindows ? '.exe' : '';
    return '${_androidNdk()}/toolchains/llvm/prebuilt/$host/bin/$name$suffix';
  }

  /// An installed LLVM with clang-cl and lld-link, as GitHub's Windows images
  /// carry. Without one the build uses MSVC's cl.exe.
  String? _windowsLlvm() {
    final candidates = [
      Platform.environment['FL_CRASHPAD_LLVM'],
      r'C:\Program Files\LLVM',
    ];
    for (final candidate in candidates) {
      if (candidate == null) continue;
      if (File('$candidate\\bin\\clang-cl.exe').existsSync() &&
          File('$candidate\\bin\\lld-link.exe').existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // Stage, archive, install

  Future<Directory> _stage(List<Directory> outs) async {
    final stage = Directory('${work.path}/stage/${target.id}');
    if (stage.existsSync()) stage.deleteSync(recursive: true);
    // Every file of the target, by its path inside the artifact, from its
    // name in the ninja output directory.
    final outputs = {
      'lib/${target.libraryFileName}': target.libraryFileName,
      if (target.os == 'android')
        'lib/${NativeTarget.trampolineFileName}':
            NativeTarget.trampolineFileName,
      'bin/${target.handlerFileName}': ?target.handlerFileName,
      if (target.os == 'windows') 'bin/crashpad_wer.dll': 'crashpad_wer.dll',
    };
    final staged = <File>[];
    for (final MapEntry(key: path, value: name) in outputs.entries) {
      final file = File('${stage.path}/$path')
        ..parent.createSync(recursive: true);
      if (target.isUniversal) {
        await _run('lipo', [
          '-create',
          for (final out in outs) '${out.path}/$name',
          '-output',
          file.path,
        ]);
      } else {
        File('${outs.single.path}/$name').copySync(file.path);
      }
      staged.add(file);
    }
    final handler = target.handlerFileName == null
        ? null
        : File('${stage.path}/bin/${target.handlerFileName}');

    switch (target.os) {
      case 'linux':
        for (final file in staged) {
          await _run('strip', ['--strip-unneeded', file.path]);
        }
        await _run('chmod', ['755', handler!.path]);
      case 'android':
        final strip = _ndkTool('llvm-strip');
        for (final file in staged) {
          await _run(strip, ['--strip-unneeded', file.path]);
        }
      case 'macos':
        for (final file in staged) {
          await _run('strip', ['-x', file.path]);
          // Stripping invalidates the linker's ad-hoc signature, and arm64
          // macOS will not run unsigned code. Real signing is the app's, later.
          await _run('codesign', ['--force', '--sign', '-', file.path]);
        }
      case 'ios':
        // Xcode signs the framework the library ends up in when the app is
        // built; there is nothing to run here, so nothing to sign.
        for (final file in staged) {
          await _run('strip', ['-x', file.path]);
        }
    }

    if (handler != null) {
      File(
        '${handler.parent.path}/crashpad_handler.rev',
      ).writeAsStringSync('${lock.crashpadRevision}\n');
    }

    final licenses = Directory('${stage.path}/LICENSES')..createSync();
    File('${crashpad.path}/LICENSE').copySync('${licenses.path}/crashpad.txt');
    File(
      '${crashpad.path}/third_party/mini_chromium/mini_chromium/LICENSE',
    ).copySync('${licenses.path}/mini_chromium.txt');
    if (target.os == 'windows') {
      File(
        '${crashpad.path}/third_party/zlib/zlib/LICENSE',
      ).copySync('${licenses.path}/zlib.txt');
    }

    File('${stage.path}/manifest.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'artifacts': lock.artifactsVersion,
        'target': target.id,
        'crashpad': lock.crashpadRevision,
        'gnArgs': _gnArgsByCpu,
      }),
    );
    return stage;
  }

  Future<File> archive(Directory stage, String? outDirectory) async {
    final dist = Directory(outDirectory ?? '${work.path}/dist')
      ..createSync(recursive: true);
    final archive = File(
      '${dist.path}/${target.archiveName(lock.artifactsVersion)}',
    );
    if (archive.existsSync()) archive.deleteSync();
    // The system tar (bsdtar on Windows and macOS), because it keeps the
    // handler's executable bit, which is the one piece of metadata that matters.
    await _run(_tar, ['-czf', archive.absolute.path, '-C', stage.path, '.']);
    return archive;
  }

  void install(Directory stage, ArtifactDirectory destination) {
    final staging = destination.directory.parent;
    staging.createSync(recursive: true);
    final copy = staging.createTempSync('.${target.id}-');
    _copyTree(stage, copy);
    File('${copy.path}/.complete').writeAsStringSync('built from source\n');
    if (destination.directory.existsSync()) {
      destination.directory.deleteSync(recursive: true);
    }
    ArtifactResolver.commit(copy, destination);
  }

  // --------------------------------------------------------------------------
  // Plumbing

  /// Windows' own bsdtar, by full path: the `tar` first on a CI runner's PATH
  /// is often Git's GNU tar, which reads `C:\...` as a remote host.
  static String get _tar => Platform.isWindows
      ? '${Platform.environment['SYSTEMROOT'] ?? r'C:\Windows'}\\System32\\tar.exe'
      : 'tar';

  static String _safe(String version) =>
      version.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');

  static void _copyTree(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final entity in from.listSync()) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entity is Directory) {
        _copyTree(entity, Directory('${to.path}/$name'));
      } else if (entity is File) {
        entity.copySync('${to.path}/$name');
      }
    }
  }

  static Future<List<int>> _download(Uri url) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('GET $url answered ${response.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await response.forEach(builder.add);
      return builder.takeBytes();
    } finally {
      client.close();
    }
  }

  static Future<void> _run(String executable, List<String> arguments) async {
    final process = await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) {
      throw ProcessException(executable, arguments, 'exited $code', code);
    }
  }

  static Future<String> _capture(
    String executable,
    List<String> arguments,
  ) async {
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
}
