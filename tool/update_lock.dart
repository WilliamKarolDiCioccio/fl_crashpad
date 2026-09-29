// Records published digests in native/artifacts.lock.json and regenerates the
// two copies of the lock that cannot read JSON: artifacts.lock.cmake for the
// plugin's CMake and artifacts.lock.txt for the pod's script.
//
//   dart run tool/update_lock.dart                          # regenerate only
//   dart run tool/update_lock.dart linux-x64=<sha256> ...   # record, then regenerate
//
// The release workflow runs it with every target's digest once the archives
// are built; test/artifacts_test.dart fails if the three files disagree.
import 'dart:convert';
import 'dart:io';

import 'package:fl_crashpad/src/build/native_artifacts.dart';

void main(List<String> arguments) {
  final native = Directory.fromUri(Platform.script.resolve('../native/'));
  final jsonFile = File('${native.path}artifacts.lock.json');
  final json = jsonDecode(jsonFile.readAsStringSync()) as Map<String, Object?>;
  final targets = json['targets']! as Map<String, Object?>;

  for (final argument in arguments) {
    final [id, digest] = argument.split('=');
    NativeTarget.byId(id);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw FormatException('not a sha256 digest', digest);
    }
    targets[id] = {'sha256': digest};
  }

  jsonFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(json)}\n',
  );
  final lock = ArtifactLock.read(jsonFile);
  File('${native.path}artifacts.lock.cmake').writeAsStringSync(lock.toCmake());
  File('${native.path}artifacts.lock.txt').writeAsStringSync(lock.toText());
}
