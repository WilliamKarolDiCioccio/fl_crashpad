import 'dart:convert';
import 'dart:typed_data';

/// Writes a small but well-formed minidump, laid out as Crashpad writes one on
/// Linux x64, so the reader's offsets are checked against bytes whose every
/// offset the test chose.
Uint8List syntheticMinidump({
  int signal = 11,
  int siCode = 1,
  int faultAddress = 0,
  int instructionPointer = 0x7f0000001234,
  Map<String, String> processAnnotations = const {'version': '1.0'},
  Map<String, String> runtimeAnnotations = const {'screen': 'editor'},
}) {
  final out = _Out();
  const streams = 5;
  out
    ..u32(0x504d444d) // MDMP
    ..u32(0xa793) // version
    ..u32(streams)
    ..u32(32) // stream directory
    ..u32(0)
    ..u32(0)
    ..u64(0);
  final directory = out.reserve(streams * 12);

  final module = out.string16('/opt/app/lib/libfl_crashpad_native.so');
  final moduleList = out.here;
  out
    ..u32(1)
    ..u64(0x7f0000000000) // base
    ..u32(0x10000) // size
    ..u32(0)
    ..u32(0)
    ..u32(module)
    ..zeros(108 - 24);

  final context = out.here;
  out
    ..zeros(0xf8)
    ..u64(instructionPointer)
    ..zeros(1232 - 0xf8 - 8);
  final exception = out.here;
  out
    ..u32(4242) // thread
    ..u32(0)
    ..u32(signal)
    ..u32(siCode)
    ..u64(0)
    ..u64(faultAddress)
    ..u32(0)
    ..u32(0)
    ..zeros(15 * 8)
    ..u32(1232)
    ..u32(context);

  final version = out.string16('6.8.0-generic');
  final system = out.here;
  out
    ..u16(9) // AMD64
    ..u16(6)
    ..u16(0)
    ..u8(16) // processors
    ..u8(0)
    ..u32(6)
    ..u32(8)
    ..u32(0)
    ..u32(0x8201) // Linux
    ..u32(version)
    ..zeros(32);

  final threads = out.here;
  out
    ..u32(3)
    ..zeros(3 * 48);

  int dictionary(Map<String, String> entries) {
    final strings = [
      for (final MapEntry(:key, :value) in entries.entries)
        (out.string8(key), out.string8(value)),
    ];
    final rva = out.here;
    out.u32(strings.length);
    for (final (key, value) in strings) {
      out
        ..u32(key)
        ..u32(value);
    }
    return rva;
  }

  final runtime = dictionary(runtimeAnnotations);
  final moduleInfo = out.here;
  out
    ..u32(1) // version
    ..u32(0)
    ..u32(0) // list annotations
    ..u32(8)
    ..u32(runtime) // simple annotations
    ..u32(0)
    ..u32(0); // annotation objects
  final moduleLinks = out.here;
  out
    ..u32(1)
    ..u32(0) // module index
    ..u32(28)
    ..u32(moduleInfo);
  final process = dictionary(processAnnotations);
  final crashpad = out.here;
  out
    ..u32(1) // version
    ..bytes([for (var i = 0; i < 16; i++) i]) // report id
    ..bytes([for (var i = 0; i < 16; i++) 0xa0 + i]) // client id
    ..u32(8)
    ..u32(process)
    ..u32(16)
    ..u32(moduleLinks)
    ..u32(0)
    ..u64(0);

  var entry = directory;
  for (final (type, rva) in [
    (4, moduleList),
    (6, exception),
    (7, system),
    (3, threads),
    (0x43500001, crashpad),
  ]) {
    out
      ..put32(entry, type)
      ..put32(entry + 4, 0)
      ..put32(entry + 8, rva);
    entry += 12;
  }
  return out.build();
}

class _Out {
  final _data = BytesBuilder();
  final _patches = <int, int>{};

  int get here => _data.length;

  void u8(int v) => _data.addByte(v);
  void u16(int v) => _data.add(
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List(),
  );
  void u32(int v) => _data.add(
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
  );
  void u64(int v) => _data.add(
    (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List(),
  );
  void bytes(List<int> b) => _data.add(b);
  void zeros(int n) => _data.add(Uint8List(n));

  int reserve(int n) {
    final at = here;
    zeros(n);
    return at;
  }

  void put32(int offset, int v) => _patches[offset] = v;

  int string16(String s) {
    final at = here;
    u32(s.length * 2);
    for (final unit in s.codeUnits) {
      u16(unit);
    }
    return at;
  }

  int string8(String s) {
    final at = here;
    final encoded = utf8.encode(s);
    u32(encoded.length);
    bytes(encoded);
    bytes([0]);
    return at;
  }

  Uint8List build() {
    final result = _data.toBytes();
    final view = ByteData.sublistView(result);
    _patches.forEach((o, v) => view.setUint32(o, v, Endian.little));
    return result;
  }
}
