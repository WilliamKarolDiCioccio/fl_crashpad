import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:fl_crashpad/src/build/native_artifacts.dart';

/// The artifacts the hook resolved for this machine — the same lookup, so the
/// handler a test starts is the one built beside the library it loaded.
ArtifactDirectory hostArtifacts() {
  final target = switch (Abi.current()) {
    Abi.linuxX64 => NativeTarget.linuxX64,
    Abi.linuxArm64 => NativeTarget.linuxArm64,
    Abi.windowsX64 => NativeTarget.windowsX64,
    Abi.windowsArm64 => NativeTarget.windowsArm64,
    Abi.macosX64 || Abi.macosArm64 => NativeTarget.macosUniversal,
    final abi => throw UnsupportedError('no fl_crashpad target for $abi'),
  };
  final lock = ArtifactLock.read(File('native/artifacts.lock.json'));
  return ArtifactResolver(
    lock: lock,
    cacheRoot: artifactCacheRoot(
      os: target.os,
      environment: Platform.environment,
    ),
  ).cached(target);
}
