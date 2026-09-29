// The build hook: finds the native library for the target being built and
// hands it to the SDK as a code asset, which bundles it and resolves the
// package's `@Native` declarations against it.
//
// On desktop only the library travels this way. The handler is an
// executable, and a code asset cannot carry one — flutter_tools rewrites every
// macOS asset as a framework with `install_name_tool`, and the Linux runner
// installs assets without their executable bit — so the plugin's own CMake and
// pod place it. Both halves come from the same artifact cache; see
// lib/src/build/native_artifacts.dart.
//
// On mobile everything travels this way, because nothing is an executable:
// Android's handler is the library itself, started through a trampoline that
// is a second library, and iOS handles crashes in process.
//
// User-defines, in the application's pubspec:
//
//   hooks:
//     user_defines:
//       fl_crashpad:
//         artifacts_dir: path/to/dir   # lib/ and bin/ of one target
//         disable: true                # no native library at all
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:fl_crashpad/src/build/native_artifacts.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.userDefines['disable'] == true) return;

    final code = input.config.code;
    final target = NativeTarget.of(
      code.targetOS.name,
      code.targetArchitecture.name,
      simulator:
          code.targetOS == OS.iOS &&
          code.iOS.targetSdk == IOSSdk.iPhoneSimulator,
    );
    // A combination without a build (32-bit Android, say): no asset, and the
    // Dart API reports itself unsupported instead of failing the app's build.
    if (target == null) return;

    final lockFile = File.fromUri(
      input.packageRoot.resolve('native/artifacts.lock.json'),
    );
    output.dependencies.add(lockFile.uri);
    final lock = ArtifactLock.read(lockFile);

    final override = input.userDefines.path('artifacts_dir');
    final resolver = ArtifactResolver(
      lock: lock,
      cacheRoot: artifactCacheRoot(
        os: Platform.operatingSystem,
        environment: Platform.environment,
      ),
    );

    final ArtifactDirectory artifacts;
    try {
      artifacts = await resolver.resolve(
        target,
        override: override == null ? null : Directory.fromUri(override),
      );
    } on ArtifactUnavailable catch (e) {
      // A crash reporter that is silently missing from a release is worse
      // than a build that stops and says why.
      throw StateError('$e');
    }

    var library = artifacts.library;
    if (target.isUniversal) {
      // The cache holds one universal binary; the SDK asks per architecture
      // and lipos the answers together itself, so hand it one slice.
      final slice = File.fromUri(
        input.outputDirectory.resolve(target.libraryFileName),
      );
      final result = await Process.run('lipo', [
        library.path,
        '-thin',
        code.targetArchitecture == Architecture.arm64 ? 'arm64' : 'x86_64',
        '-output',
        slice.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('fl_crashpad: lipo -thin failed: ${result.stderr}');
      }
      library = slice;
    }

    output.dependencies.add(artifacts.library.uri);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'fl_crashpad_native',
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );

    if (target.os == 'android') {
      // The handler trampoline. No Dart code looks it up: it is an asset only
      // so that the app's build copies it into jniLibs beside the library,
      // under its own file name, which is where the shim looks for it. It is
      // an executable in all but name, and that is fine — on Android a code
      // asset is copied and nothing more.
      output.dependencies.add(artifacts.trampoline.uri);
      output.assets.code.add(
        CodeAsset(
          package: input.packageName,
          name: 'fl_crashpad_trampoline',
          linkMode: DynamicLoadingBundled(),
          file: artifacts.trampoline.uri,
        ),
      );
    }
  });
}
