// Enough of a minidump reader to show somebody what a report holds before it
// is sent: what happened, where, on what machine, and every annotation — the
// things a person deciding whether to upload a crash would want to see.
//
// Not a symboliser and not a stack walker: those need symbol files and a
// thread's register context, and are the crash server's job. The layouts are
// Microsoft's MINIDUMP_* structures and Crashpad's own stream,
// minidump/minidump_extensions.h in Crashpad, which is the reference for the
// offsets below.
import 'dart:convert';
import 'dart:typed_data';

/// A minidump, read.
class Minidump {
  Minidump._({
    required this.exception,
    required this.system,
    required this.modules,
    required this.threadCount,
    required this.crashpad,
  });

  /// Reads [bytes]; throws [FormatException] if they are not a minidump.
  factory Minidump.parse(Uint8List bytes) {
    final reader = _Reader(bytes);
    if (bytes.length < 32 || reader.u32(0) != _signature) {
      throw const FormatException('not a minidump');
    }
    final streamCount = reader.u32(8);
    final directory = reader.u32(12);

    MinidumpException? exception;
    var exceptionContext = 0;
    MinidumpSystem? system;
    var modules = const <MinidumpModule>[];
    var threadCount = 0;
    CrashpadStream? crashpad;

    for (var i = 0; i < streamCount; i++) {
      final entry = directory + i * 12;
      final type = reader.u32(entry);
      final rva = reader.u32(entry + 8);
      switch (type) {
        case _threadList:
          threadCount = reader.u32(rva);
        case _moduleList:
          modules = _modules(reader, rva);
        case _exception:
          exception = MinidumpException(
            threadId: reader.u32(rva),
            code: reader.u32(rva + 8),
            flags: reader.u32(rva + 12),
            address: reader.u64(rva + 24),
          );
          // After the 152-byte MINIDUMP_EXCEPTION: the crashing thread's
          // register context, as a size and an RVA.
          exceptionContext = reader.u32(rva + 8 + 152 + 4);
        case _systemInfo:
          system = MinidumpSystem(
            architecture: reader.u16(rva),
            processors: reader.u8(rva + 6),
            major: reader.u32(rva + 8),
            minor: reader.u32(rva + 12),
            build: reader.u32(rva + 16),
            platform: reader.u32(rva + 20),
            version: reader.string16(reader.u32(rva + 24)),
          );
        case _crashpadInfo:
          crashpad = _crashpad(reader, rva);
      }
    }
    if (exception != null && system != null && exceptionContext != 0) {
      exception = exception.withInstructionPointer(
        _instructionPointer(reader, exceptionContext, system.architecture),
      );
    }
    return Minidump._(
      exception: exception,
      system: system,
      modules: modules,
      threadCount: threadCount,
      crashpad: crashpad,
    );
  }

  final MinidumpException? exception;
  final MinidumpSystem? system;
  final List<MinidumpModule> modules;
  final int threadCount;
  final CrashpadStream? crashpad;

  /// The module [address] falls inside, if any.
  MinidumpModule? moduleAt(int address) {
    for (final module in modules) {
      if (address >= module.base && address < module.base + module.size) {
        return module;
      }
    }
    return null;
  }

  static const _signature = 0x504d444d; // "MDMP"
  static const _threadList = 3;
  static const _moduleList = 4;
  static const _exception = 6;
  static const _systemInfo = 7;
  static const _crashpadInfo = 0x43500001;

  /// The program counter in a thread context, for the two architectures
  /// fl_crashpad builds for. The layouts are Crashpad's MinidumpContextAMD64
  /// (Windows' CONTEXT, `Rip` at 0xf8) and MinidumpContextARM64 (flags, cpsr,
  /// x0–x30, sp, then pc).
  static int? _instructionPointer(_Reader reader, int rva, int architecture) =>
      switch (architecture) {
        9 => reader.u64(rva + 0xf8),
        12 || 0x8003 => reader.u64(rva + 8 + 31 * 8 + 8),
        _ => null,
      };

  static List<MinidumpModule> _modules(_Reader reader, int rva) {
    final count = reader.u32(rva);
    return [
      for (var i = 0; i < count; i++)
        // MINIDUMP_MODULE is 108 bytes: base, size, checksum, timestamp,
        // then the RVA of its name.
        MinidumpModule(
          path: reader.string16(reader.u32(rva + 4 + i * 108 + 20)),
          base: reader.u64(rva + 4 + i * 108),
          size: reader.u32(rva + 4 + i * 108 + 8),
        ),
    ];
  }

  static CrashpadStream _crashpad(_Reader reader, int rva) {
    // MinidumpCrashpadInfo: version (0), report id (4), client id (20), then
    // the process annotations (36) and the per-module list (44) as location
    // descriptors — a size, then the RVA.
    final process = reader.dictionary(reader.u32(rva + 40));
    final listRva = reader.u32(rva + 48);
    final modules = <int, ModuleAnnotations>{};
    if (listRva != 0) {
      final count = reader.u32(listRva);
      for (var i = 0; i < count; i++) {
        final link = listRva + 4 + i * 12;
        final index = reader.u32(link);
        final info = reader.u32(link + 8);
        // MinidumpModuleCrashpadInfo: version, list annotations, simple
        // annotations, annotation objects — each a location descriptor.
        modules[index] = ModuleAnnotations(
          simple: reader.dictionary(reader.u32(info + 12 + 4)),
          objects: reader.annotationObjects(reader.u32(info + 20 + 4)),
        );
      }
    }
    return CrashpadStream(
      reportId: reader.uuid(rva + 4),
      clientId: reader.uuid(rva + 20),
      processAnnotations: process,
      moduleAnnotations: modules,
    );
  }
}

/// What ended the process: a signal on Linux, a Mach exception on macOS, an
/// exception code on Windows.
class MinidumpException {
  const MinidumpException({
    required this.threadId,
    required this.code,
    required this.flags,
    required this.address,
    this.instructionPointer,
  });

  final int threadId;
  final int code;

  /// On Linux the signal's `si_code`, which is signed: -6 is `SI_TKILL`, a
  /// signal sent by the process to itself, as `abort()` does.
  final int flags;

  /// The address the exception is about. For a bad access that is the data
  /// address, not the code: a write through null says 0.
  final int address;

  /// Where the crashing thread was executing, from its register context.
  final int? instructionPointer;

  MinidumpException withInstructionPointer(int? pc) => MinidumpException(
    threadId: threadId,
    code: code,
    flags: flags,
    address: address,
    instructionPointer: pc,
  );

  /// [flags] as the signed `si_code` it is on Linux.
  int get signedFlags => flags.toSigned(32);

  /// A name for [code] on [platform] (a [MinidumpSystem.platform]).
  String describe(int? platform) => switch (platform) {
    MinidumpSystem.linux => _linuxSignals[code] ?? 'signal $code',
    MinidumpSystem.macos => _machExceptions[code] ?? 'exception $code',
    MinidumpSystem.windows =>
      _windowsExceptions[code] ?? '0x${code.toRadixString(16).padLeft(8, '0')}',
    _ => 'code $code',
  };

  static const _linuxSignals = {
    4: 'SIGILL',
    5: 'SIGTRAP',
    6: 'SIGABRT',
    7: 'SIGBUS',
    8: 'SIGFPE',
    11: 'SIGSEGV',
    3: 'SIGQUIT',
    31: 'SIGSYS',
    // What Crashpad records for a dump taken without a crash.
    0xffffffff: 'no crash (a dump taken on request)',
  };
  static const _machExceptions = {
    1: 'EXC_BAD_ACCESS',
    2: 'EXC_BAD_INSTRUCTION',
    3: 'EXC_ARITHMETIC',
    5: 'EXC_SOFTWARE',
    6: 'EXC_BREAKPOINT',
    10: 'EXC_CRASH',
    0x43507378: 'no crash (a dump taken on request)',
  };
  static const _windowsExceptions = {
    0xc0000005: 'EXCEPTION_ACCESS_VIOLATION',
    0xc00000fd: 'EXCEPTION_STACK_OVERFLOW',
    0xc0000409: 'STATUS_STACK_BUFFER_OVERRUN (fast fail)',
    0x80000003: 'EXCEPTION_BREAKPOINT',
    0xc000001d: 'EXCEPTION_ILLEGAL_INSTRUCTION',
    0xc0000094: 'EXCEPTION_INT_DIVIDE_BY_ZERO',
    0x0517a7ed: 'no crash (a dump taken on request)',
  };
}

class MinidumpSystem {
  const MinidumpSystem({
    required this.architecture,
    required this.processors,
    required this.major,
    required this.minor,
    required this.build,
    required this.platform,
    required this.version,
  });

  static const windows = 2;
  static const macos = 0x8101;
  static const linux = 0x8201;

  final int architecture;
  final int processors;
  final int major;
  final int minor;
  final int build;
  final int platform;

  /// The OS's own description of itself, such as a kernel release.
  final String version;

  String get os => switch (platform) {
    windows => 'Windows',
    macos => 'macOS',
    linux => 'Linux',
    _ => 'platform 0x${platform.toRadixString(16)}',
  };

  String get cpu => switch (architecture) {
    0 => 'x86',
    9 => 'x64',
    12 || 0x8003 => 'arm64',
    5 => 'arm',
    _ => 'architecture $architecture',
  };
}

class MinidumpModule {
  const MinidumpModule({
    required this.path,
    required this.base,
    required this.size,
  });

  final String path;
  final int base;
  final int size;

  String get name => path.split(RegExp(r'[/\\]')).last;
}

/// Crashpad's own stream: the report's identity and every annotation.
class CrashpadStream {
  const CrashpadStream({
    required this.reportId,
    required this.clientId,
    required this.processAnnotations,
    required this.moduleAnnotations,
  });

  final String reportId;
  final String clientId;

  /// Handed to the handler at start: `CrashpadOptions.annotations`.
  final Map<String, String> processAnnotations;

  /// Read from each module's memory at the crash, keyed by module index.
  /// fl_crashpad's runtime annotations are in its library's entry.
  final Map<int, ModuleAnnotations> moduleAnnotations;
}

class ModuleAnnotations {
  const ModuleAnnotations({required this.simple, required this.objects});

  /// `Crashpad.annotations`, when the module is fl_crashpad's library.
  final Map<String, String> simple;

  /// Crashpad's typed annotation objects, where the value is a string.
  final Map<String, String> objects;

  bool get isEmpty => simple.isEmpty && objects.isEmpty;
}

/// Little-endian reads that fail as a [FormatException] rather than a
/// [RangeError] when a minidump is truncated or lies about an offset.
class _Reader {
  _Reader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;

  void _need(int offset, int length) {
    if (offset < 0 || offset + length > bytes.length) {
      throw FormatException('minidump truncated at offset $offset');
    }
  }

  int u8(int offset) {
    _need(offset, 1);
    return data.getUint8(offset);
  }

  int u16(int offset) {
    _need(offset, 2);
    return data.getUint16(offset, Endian.little);
  }

  int u32(int offset) {
    _need(offset, 4);
    return data.getUint32(offset, Endian.little);
  }

  int u64(int offset) {
    _need(offset, 8);
    return data.getUint64(offset, Endian.little);
  }

  /// A MINIDUMP_STRING: a byte length, then UTF-16LE.
  String string16(int rva) {
    if (rva == 0) return '';
    final length = u32(rva);
    _need(rva + 4, length);
    final units = <int>[
      for (var i = 0; i < length ~/ 2; i++) u16(rva + 4 + i * 2),
    ];
    return String.fromCharCodes(units);
  }

  /// Crashpad's MinidumpUTF8String and MinidumpByteArray share one shape: a
  /// length, then that many bytes.
  String string8(int rva) {
    if (rva == 0) return '';
    final length = u32(rva);
    _need(rva + 4, length);
    return utf8.decode(
      bytes.sublist(rva + 4, rva + 4 + length),
      allowMalformed: true,
    );
  }

  /// A MinidumpSimpleStringDictionary: a count, then key/value RVA pairs.
  Map<String, String> dictionary(int rva) {
    if (rva == 0) return const {};
    final count = u32(rva);
    return {
      for (var i = 0; i < count; i++)
        string8(u32(rva + 4 + i * 8)): string8(u32(rva + 8 + i * 8)),
    };
  }

  /// A MinidumpAnnotationList, keeping the string-typed entries.
  Map<String, String> annotationObjects(int rva) {
    if (rva == 0) return const {};
    final count = u32(rva);
    const string = 1; // crashpad::Annotation::Type::kString
    return {
      for (var i = 0; i < count; i++)
        if (u16(rva + 4 + i * 12 + 4) == string)
          string8(u32(rva + 4 + i * 12)): string8(u32(rva + 4 + i * 12 + 8)),
    };
  }

  /// A UUID as Crashpad prints one: the first three fields little-endian.
  String uuid(int offset) {
    _need(offset, 16);
    String hex(int value, int width) =>
        value.toRadixString(16).padLeft(width, '0');
    final tail = [
      for (var i = 8; i < 16; i++) hex(bytes[offset + i], 2),
    ].join();
    return '${hex(u32(offset), 8)}-${hex(u16(offset + 4), 4)}-'
        '${hex(u16(offset + 6), 4)}-${tail.substring(0, 4)}-'
        '${tail.substring(4)}';
  }
}
