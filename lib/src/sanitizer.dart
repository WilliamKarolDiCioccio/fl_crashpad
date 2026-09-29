import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Takes what identifies a person out of a crash report, and leaves what
/// identifies the *bug*.
///
/// **The rules are ripple_telemetry's `Redactor`**, the one every log line of
/// ripple_effect goes through, copied rule for rule and in the same order —
/// its fixture runs against [sanitizeText] in this package's suite, so the two
/// cannot drift without a test saying so. Three things are added for crash
/// reports, which carry what a log line never does:
///
/// - the process's **environment**, so a variable whose *name* admits to a
///   secret (`AWS_SECRET_ACCESS_KEY=...`, `SESSION_COOKIE=...`) has its value
///   masked whatever the value looks like;
/// - [secrets]: literal strings the application knows are private — an
///   account id, a licence key — masked wherever they appear;
/// - [sensitiveRoots]: folders whose *names* are private, the equivalent of
///   the redactor's project roots, replaced with `<private>`.
///
/// **The order is load-bearing**, for the reasons the original gives: the
/// home directory contains the username, so home goes first and the bare
/// username is a mop-up; most usernames are the local part of an email, so
/// emails go before the username; credentials go first of all, before any
/// other rule can cut one in half.
///
/// **Over-redaction is the failure worth fearing here too.** A path keeps its
/// last segment — `libapp.so` is how a crash server finds the symbols, and the
/// directory above it is nobody's business — and the application's own
/// install directory is exempt, because it is where every module of the
/// crashed app was loaded from.
///
/// Two modes over one implementation:
///
/// - [sanitizeText] returns the redacted string, exactly as the log redactor
///   would write it. Used for text attachments.
/// - [sanitizeBytes] masks a minidump **in place, byte for byte**: every text
///   run inside the binary — UTF-8 and UTF-16LE, which is how Windows keeps
///   paths and the environment — is redacted, and each redacted span is
///   overwritten with a marker of the *same length*. Nothing moves, so every
///   offset in the minidump stays valid and a crash server reads it as it
///   would any other; it just finds `<home>*****/Documents` where a folder
///   name used to be.
class ReportSanitizer {
  ReportSanitizer({
    this.home,
    String? userName,
    Iterable<String> exemptRoots = const [],
    Iterable<String> sensitiveRoots = const [],
    Iterable<String> secrets = const [],
    this.windows = false,
  }) : userName = (userName != null && userName.length >= 3) ? userName : null,
       exemptRoots = List.unmodifiable(exemptRoots),
       sensitiveRoots = List.unmodifiable(
         sensitiveRoots.map(_normalise).where((r) => r.isNotEmpty).toList()
           ..sort((a, b) => b.length.compareTo(a.length)),
       ),
       secrets = List.unmodifiable(
         secrets.where((s) => s.length >= 4).toList()
           ..sort((a, b) => b.length.compareTo(a.length)),
       );

  /// The sanitizer for the machine this runs on: its home, its account name,
  /// and the running application's folder as exempt.
  ///
  /// It reads the environment when it is made, which is the next launch after
  /// a crash — the same user and the same install, which is what a report
  /// needs cleaning of.
  factory ReportSanitizer.forHost({
    Iterable<String> exemptRoots = const [],
    Iterable<String> sensitiveRoots = const [],
    Iterable<String> secrets = const [],
  }) {
    final environment = Platform.environment;
    return ReportSanitizer(
      home: environment['HOME'] ?? environment['USERPROFILE'],
      userName:
          environment['USER'] ??
          environment['USERNAME'] ??
          environment['LOGNAME'],
      exemptRoots: [
        ...exemptRoots,
        File(Platform.resolvedExecutable).parent.path,
      ],
      sensitiveRoots: sensitiveRoots,
      secrets: secrets,
      windows: Platform.isWindows,
    );
  }

  /// Bumped whenever a rule changes what it removes, and recorded with every
  /// report sanitised — so a report cleaned by an older set of rules is known
  /// to have been.
  static const int rulesVersion = 2;

  /// Replaced with `~` in text, `<home>` in a minidump.
  final String? home;

  /// Replaced on its own once [home] has had its turn. Ignored below three
  /// characters: a two-letter name matches inside ordinary words.
  final String? userName;

  /// Directories a path may stay whole inside.
  final List<String> exemptRoots;

  /// Folders whose names are private, longest first.
  final List<String> sensitiveRoots;

  /// Literal strings masked wherever they appear, longest first.
  final List<String> secrets;

  /// Whether paths compare case-insensitively and may use `\`.
  final bool windows;

  /// Runs every rule over [text] and returns what is left.
  String sanitizeText(String text) {
    if (text.isEmpty) return text;
    return _redact(text).text;
  }

  /// Masks [bytes] in place and returns how many bytes were overwritten.
  int sanitizeBytes(Uint8List bytes) {
    var masked = 0;
    masked += _utf8Runs(bytes);
    masked += _utf16Runs(bytes, 0);
    masked += _utf16Runs(bytes, 1);
    return masked;
  }

  // ------------------------------------------------------------ the rules

  _Tracked _redact(String text) {
    final t = _Tracked(text);
    for (final secret in secrets) {
      t.replaceAll(_literal(secret), (_) => '<secret>', 'secret');
    }
    _credentials(t);
    t.replaceAll(_urlCredentials, (_) => '://<redacted>@', 'redacted');
    for (final root in sensitiveRoots) {
      _replaceRoot(t, root, '<private>', 'private');
    }
    final home = this.home;
    if (home != null && home.isNotEmpty) _replaceRoot(t, home, '~', 'home');
    t.replaceAll(
      _email,
      (m) => _versionedLibrary.hasMatch(m[0]!) ? m[0]! : '<email>',
      'email',
    );
    if (_userNamePattern case final pattern?) {
      t.replaceAll(pattern, (_) => '<user>', 'user');
    }
    t.replaceAll(_residualPath, _shortenPath, 'path');
    t.replaceAll(_ipv4, (m) {
      final value = m[0]!;
      return (value == '127.0.0.1' || value == '0.0.0.0') ? value : '<ip>';
    }, 'ip');
    t.replaceAll(_ipv6, (m) => m[0] == '::1' ? m[0]! : '<ip>', 'ip');
    return t;
  }

  static final RegExp _githubToken = RegExp(
    r'\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}',
  );
  static final RegExp _githubPat = RegExp(r'\bgithub_pat_[A-Za-z0-9_]{20,}');
  static final RegExp _openAiKey = RegExp(r'\bsk-[A-Za-z0-9_\-]{16,}');
  static final RegExp _authHeader = RegExp(
    r'\b(Bearer|Basic|Token)\s+[A-Za-z0-9._\-~+/=]{8,}',
    caseSensitive: false,
  );
  static final RegExp _namedSecret = RegExp(
    r'''\b(api[_-]?key|apikey|access[_-]?token|token|secret|password|passwd|pwd|auth)\b(\s*[:=]\s*)(?:"|')?[^\s"',;}\]]+''',
    caseSensitive: false,
  );

  /// Not in the log redactor: an environment variable whose name admits what
  /// its value is. `\b` cannot find `TOKEN` inside `GITHUB_TOKEN`, because
  /// `_` is a word character, so [_namedSecret] misses every conventional
  /// variable name — and a minidump carries the whole environment.
  static final RegExp _secretVariable = RegExp(
    r'(?<![A-Za-z0-9_])([A-Za-z][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?|COOKIE|SESSION|AUTH)[A-Za-z0-9_]*)=([^\s]+)',
    caseSensitive: false,
  );

  static void _credentials(_Tracked t) {
    t.replaceAll(_githubToken, (_) => '<redacted>', 'redacted');
    t.replaceAll(_githubPat, (_) => '<redacted>', 'redacted');
    t.replaceAll(_openAiKey, (_) => '<redacted>', 'redacted');
    t.replaceAll(_authHeader, (m) => '${m[1]} <redacted>', 'redacted');
    t.replaceAll(_secretVariable, (m) => '${m[1]}=<redacted>', 'redacted');
    t.replaceAll(_namedSecret, (m) => '${m[1]}${m[2]}<redacted>', 'redacted');
  }

  static final RegExp _urlCredentials = RegExp(r'://[^\s/@:]+(?::[^\s/@]*)?@');

  /// Unicode classes spelled out, never `\w`: Dart's is ASCII, and
  /// `josé@example.com` used to go into a log untouched because of it.
  static final RegExp _email = RegExp(
    r'[\p{L}\p{N}_.+-]+@[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)+',
    unicode: true,
  );

  /// A shared library versioned the HIDL way, `android.hardware.drm@1.4.so`,
  /// which the email rule reads as an address at `1.4.so`. Android loads
  /// dozens into every app, and their names are what a minidump's module list
  /// is symbolicated by: masking them breaks the report for no privacy gain.
  /// The one place the rules here depart from the log redactor's other than
  /// by adding: a log never names a HIDL library.
  static final RegExp _versionedLibrary = RegExp(
    r'@\d+(?:\.\d+)*\.so(?:\.\d+)*$',
  );

  late final RegExp? _userNamePattern = userName == null
      ? null
      : RegExp(
          '(?<![\\p{L}\\p{N}_])${RegExp.escape(userName!)}(?![\\p{L}\\p{N}_])',
          unicode: true,
          caseSensitive: !windows,
        );

  Pattern _literal(String value) =>
      windows ? RegExp(RegExp.escape(value), caseSensitive: false) : value;

  void _replaceRoot(_Tracked t, String root, String token, String kind) {
    final trimmed = root.endsWith('/') || root.endsWith(r'\')
        ? root.substring(0, root.length - 1)
        : root;
    for (final spelling in {
      trimmed,
      trimmed.replaceAll(r'\', '/'),
      trimmed.replaceAll('/', r'\'),
    }) {
      if (spelling.isEmpty) continue;
      t.replaceAll(_literal(spelling), (_) => token, kind);
    }
  }

  static final RegExp _residualPath = RegExp(
    r'(?:[A-Za-z]:)?(?:[\\/][^\s\\/:*?"<>|,;)\]]+){2,}',
  );

  /// What may not sit immediately before a path for it to count as one: the
  /// tail of a URL, or the output of an earlier rule.
  static final RegExp _notAPathStart = RegExp(r'[>~:/\\\w]');

  String _shortenPath(Match match) {
    final path = match[0]!;
    if (match.start > 0 &&
        _notAPathStart.hasMatch(match.input[match.start - 1])) {
      return path;
    }
    for (final root in exemptRoots) {
      if (root.isEmpty) continue;
      final inside = windows
          ? path.toLowerCase().startsWith(root.toLowerCase())
          : path.startsWith(root);
      if (inside) return path;
    }
    final separator = path.contains(r'\') ? r'\' : '/';
    final last = path.split(RegExp(r'[\\/]')).last;
    return last.isEmpty ? '<path>' : '<path>$separator$last';
  }

  static final RegExp _ipv4 = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}\b');
  static final RegExp _ipv6 = RegExp(
    r'\b(?:[A-Fa-f0-9]{1,4}:){3,7}[A-Fa-f0-9]{1,4}\b',
  );

  static String _normalise(String path) {
    var out = path;
    while (out.length > 1 && (out.endsWith('/') || out.endsWith(r'\'))) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  // ------------------------------------------------------- in a minidump

  /// Text runs shorter than this are not worth a regex: nothing a rule
  /// removes fits in five characters.
  static const int _minimumRun = 6;

  /// UTF-8 runs: printable ASCII and well-formed multi-byte sequences, as
  /// Linux and macOS keep paths, the environment and annotations.
  int _utf8Runs(Uint8List bytes) {
    var masked = 0;
    var i = 0;
    while (i < bytes.length) {
      final start = i;
      final units = <int>[];
      final offsets = <int>[]; // byte offset of each UTF-16 code unit
      while (i < bytes.length) {
        final width = _utf8Width(bytes, i);
        if (width == 0) break;
        final codePoint = _decodeUtf8(bytes, i, width);
        if (codePoint > 0xffff) {
          final v = codePoint - 0x10000;
          units
            ..add(0xd800 + (v >> 10))
            ..add(0xdc00 + (v & 0x3ff));
          offsets
            ..add(i)
            ..add(i);
        } else {
          units.add(codePoint);
          offsets.add(i);
        }
        i += width;
      }
      if (i - start >= _minimumRun) {
        offsets.add(i);
        masked += _maskRun(
          String.fromCharCodes(units),
          (unit) => (offsets[unit], _nextOffset(offsets, unit)),
          (from, to, marker) {
            for (var k = 0; k < to - from; k++) {
              bytes[from + k] = marker.codeUnitAt(k);
            }
          },
          bytesPerChar: 1,
        );
      }
      i = i == start ? i + 1 : i;
    }
    return masked;
  }

  /// UTF-16LE runs at one alignment: how Windows keeps paths and its
  /// environment, and how a minidump spells every module name.
  int _utf16Runs(Uint8List bytes, int alignment) {
    var masked = 0;
    var i = alignment;
    while (i + 1 < bytes.length) {
      final start = i;
      var narrow = 0;
      while (i + 1 < bytes.length) {
        final unit = bytes[i] | (bytes[i + 1] << 8);
        if (!_printable(unit)) break;
        if (unit < 0x100) narrow++;
        i += 2;
      }
      final count = (i - start) ~/ 2;
      // Mostly-Latin, or it is a run of ordinary bytes misread two at a time
      // as CJK — which is what UTF-8 text looks like at the wrong width.
      if (count >= _minimumRun && narrow * 2 >= count) {
        final text = String.fromCharCodes([
          for (var k = start; k < i; k += 2) bytes[k] | (bytes[k + 1] << 8),
        ]);
        masked += _maskRun(
          text,
          (unit) => (start + unit * 2, start + unit * 2 + 2),
          (from, to, marker) {
            for (var k = 0; k < (to - from) ~/ 2; k++) {
              bytes[from + k * 2] = marker.codeUnitAt(k);
              bytes[from + k * 2 + 1] = 0;
            }
          },
          bytesPerChar: 2,
        );
      }
      i = i == start ? i + 2 : i;
    }
    return masked;
  }

  /// Redacts one run and overwrites every masked span with a marker of its
  /// own length. [range] maps a code unit to its bytes; [write] puts an ASCII
  /// marker over a byte range, in the run's encoding — one byte a character
  /// in UTF-8, two in UTF-16.
  int _maskRun(
    String text,
    (int, int) Function(int unit) range,
    void Function(int from, int to, String marker) write, {
    required int bytesPerChar,
  }) {
    final tracked = _redact(text);
    var masked = 0;
    var unit = 0;
    while (unit < text.length) {
      final kind = tracked.maskedKind[unit];
      if (kind == null) {
        unit++;
        continue;
      }
      var end = unit;
      while (end < text.length && tracked.maskedKind[end] == kind) {
        end++;
      }
      final (from, _) = range(unit);
      final (_, to) = range(end - 1);
      final width = to - from;
      write(from, to, _marker(kind, width ~/ bytesPerChar));
      masked += width;
      unit = end;
    }
    return masked;
  }

  /// `<home>****`, cut to [length]: the kind first, so a reader of the dump
  /// knows what was there, then filler so nothing after it moves.
  static String _marker(String kind, int length) {
    final label = '<$kind>';
    if (length <= label.length) return '*' * length;
    return label + '*' * (length - label.length);
  }

  static int _nextOffset(List<int> offsets, int unit) {
    // A surrogate pair's two units share a start; the pair's bytes end where
    // the next distinct offset begins.
    var next = unit + 1;
    while (next < offsets.length - 1 && offsets[next] == offsets[unit]) {
      next++;
    }
    return offsets[next];
  }

  static bool _printable(int unit) =>
      (unit >= 0x20 && unit < 0x7f) ||
      unit == 0x09 ||
      (unit >= 0xa0 && unit < 0xd800) ||
      (unit >= 0xe000 && unit < 0xfffe);

  /// The width of a well-formed, printable UTF-8 sequence at [i], or 0.
  static int _utf8Width(Uint8List b, int i) {
    final c = b[i];
    if ((c >= 0x20 && c < 0x7f) || c == 0x09) return 1;
    int width;
    if (c >= 0xc2 && c < 0xe0) {
      width = 2;
    } else if (c >= 0xe0 && c < 0xf0) {
      width = 3;
    } else if (c >= 0xf0 && c < 0xf5) {
      width = 4;
    } else {
      return 0;
    }
    if (i + width > b.length) return 0;
    for (var k = 1; k < width; k++) {
      if (b[i + k] & 0xc0 != 0x80) return 0;
    }
    final cp = _decodeUtf8(b, i, width);
    if (cp < 0xa0 || (cp >= 0xd800 && cp < 0xe000) || cp > 0x10ffff) return 0;
    if (width == 3 && cp < 0x800) return 0;
    if (width == 4 && cp < 0x10000) return 0;
    return width;
  }

  static int _decodeUtf8(Uint8List b, int i, int width) => switch (width) {
    1 => b[i],
    2 => ((b[i] & 0x1f) << 6) | (b[i + 1] & 0x3f),
    3 => ((b[i] & 0x0f) << 12) | ((b[i + 1] & 0x3f) << 6) | (b[i + 2] & 0x3f),
    _ =>
      ((b[i] & 0x07) << 18) |
          ((b[i + 1] & 0x3f) << 12) |
          ((b[i + 2] & 0x3f) << 6) |
          (b[i + 3] & 0x3f),
  };
}

/// A string being redacted rule by rule, which remembers which of its
/// *original* characters each replacement covered.
///
/// The log redactor rewrites text in place, one rule after another, and each
/// rule sees what the ones before it left — `~/tales` is safe from the path
/// rule only because the home rule has already run. Keeping that exact
/// behaviour, and knowing afterwards which original characters went, is what
/// lets one implementation both produce the log redactor's output and mask a
/// minidump without moving a byte.
class _Tracked {
  _Tracked(String original)
    : text = original,
      _origin = List<int>.generate(original.length, (i) => i),
      maskedKind = List<String?>.filled(original.length, null);

  String text;

  /// For each character of [text], its index in the original, or -1 for a
  /// character a rule wrote.
  List<int> _origin;

  /// For each original character, the rule that removed it, if one did.
  final List<String?> maskedKind;

  void replaceAll(
    Pattern pattern,
    String Function(Match match) replacement,
    String kind,
  ) {
    final matches = pattern.allMatches(text).toList();
    if (matches.isEmpty) return;
    final out = StringBuffer();
    final origin = <int>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.end == match.start) continue;
      out.write(text.substring(cursor, match.start));
      origin.addAll(_origin.getRange(cursor, match.start));
      final found = match[0]!;
      final replaced = replacement(match);
      if (replaced == found) {
        out.write(found);
        origin.addAll(_origin.getRange(match.start, match.end));
      } else {
        // What the replacement kept of the match — `Bearer ` in front, the
        // basename behind — stays mapped to where it came from; what it
        // removed is marked as removed.
        var prefix = 0;
        final limit = found.length < replaced.length
            ? found.length
            : replaced.length;
        while (prefix < limit && found[prefix] == replaced[prefix]) {
          prefix++;
        }
        var suffix = 0;
        while (suffix < limit - prefix &&
            found[found.length - 1 - suffix] ==
                replaced[replaced.length - 1 - suffix]) {
          suffix++;
        }
        for (var k = match.start + prefix; k < match.end - suffix; k++) {
          final at = _origin[k];
          if (at >= 0) maskedKind[at] ??= kind;
        }
        out.write(replaced);
        origin
          ..addAll(_origin.getRange(match.start, match.start + prefix))
          ..addAll(List.filled(replaced.length - prefix - suffix, -1))
          ..addAll(_origin.getRange(match.end - suffix, match.end));
      }
      cursor = match.end;
    }
    out.write(text.substring(cursor));
    origin.addAll(_origin.getRange(cursor, _origin.length));
    text = out.toString();
    _origin = origin;
  }
}

/// Sanitises one report's files: the minidump in place — same length, same
/// file, so a database that keeps its metadata on the file itself (macOS
/// keeps it in extended attributes) keeps it — and every attachment.
///
/// Returns how many bytes were masked. Throws a [FileSystemException] if the
/// minidump cannot be opened, which happens when the handler moves it mid-way;
/// the caller leaves the report for next time.
int sanitizeReportFiles(
  ReportSanitizer sanitizer,
  File minidump, {
  Directory? attachments,
}) {
  var masked = _sanitizeInPlace(sanitizer, minidump);
  if (attachments != null && attachments.existsSync()) {
    for (final file in attachments.listSync().whereType<File>()) {
      final bytes = file.readAsBytesSync();
      final text = _asText(bytes);
      if (text != null) {
        final cleaned = sanitizer.sanitizeText(text);
        if (cleaned != text) {
          file.writeAsStringSync(cleaned, flush: true);
          masked += bytes.length;
        }
      } else {
        masked += _sanitizeInPlace(sanitizer, file);
      }
    }
  }
  return masked;
}

int _sanitizeInPlace(ReportSanitizer sanitizer, File file) {
  final original = file.readAsBytesSync();
  final cleaned = Uint8List.fromList(original);
  final masked = sanitizer.sanitizeBytes(cleaned);
  if (masked == 0) return 0;
  // FileMode.append opens for reading and writing without truncating; the
  // writes below go where setPositionSync puts them.
  final handle = file.openSync(mode: FileMode.append);
  try {
    var i = 0;
    while (i < original.length) {
      if (original[i] == cleaned[i]) {
        i++;
        continue;
      }
      var end = i;
      while (end < original.length && original[end] != cleaned[end]) {
        end++;
      }
      handle
        ..setPositionSync(i)
        ..writeFromSync(cleaned, i, end);
      i = end;
    }
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
  return masked;
}

/// [bytes] as text if they are UTF-8 with no NUL — a log file, JSON — or null
/// for anything binary.
String? _asText(Uint8List bytes) {
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}
