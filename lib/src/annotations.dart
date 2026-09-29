import 'dart:convert';

import 'package:ffi/ffi.dart';

import 'exception.dart';
import 'ffi/bindings.dart';

/// Annotations that can change while the app runs — the screen that is open,
/// the document being edited, the last thing the user did — read at the
/// moment of a crash.
///
/// They live in memory Crashpad reads without allocating, which is why they
/// are small: at most [maxEntries] of them, each key at most [maxKeyBytes]
/// and each value at most [maxValueBytes] bytes of UTF-8. Anything larger
/// belongs in an attachment ([CrashpadOptions.attachments]); anything fixed
/// for the life of the process belongs in [CrashpadOptions.annotations], which
/// travel on the handler's command line and have no such limit.
///
/// They can be set before [Crashpad.start], and a native library in the same
/// process can set them too through `fl_crashpad_annotation_set` — which is
/// also why this class cannot read them back: it is not the only writer.
final class CrashpadAnnotations {
  CrashpadAnnotations.internal();

  static const int maxKeyBytes = 255;
  static const int maxValueBytes = 255;
  static const int maxEntries = 64;

  /// Sets [key] to [value], replacing any value it had.
  ///
  /// Throws [ArgumentError] for an empty key, a NUL character or a string
  /// over the size limits, and a [CrashpadException] with
  /// [CrashpadErrorCode.limitExceeded] when [maxEntries] are already set.
  void operator []=(String key, String value) => set(key, value);

  /// The same as `annotations[key] = value`.
  void set(String key, String value) {
    _check(key, 'key', maxKeyBytes);
    if (key.isEmpty) throw ArgumentError.value(key, 'key', 'is empty');
    _check(value, 'value', maxValueBytes);
    using((arena) {
      final status = nativeAnnotationSet(
        key.toNativeUtf8(allocator: arena),
        value.toNativeUtf8(allocator: arena),
      );
      if (status == statusLimitExceeded) {
        throw const CrashpadException(
          CrashpadErrorCode.limitExceeded,
          'there are already $maxEntries runtime annotations',
        );
      }
      assert(status == statusOk, 'checked above: $status');
    });
  }

  /// Removes [key], if it is set.
  void remove(String key) {
    if (key.isEmpty) return;
    using(
      (arena) => nativeAnnotationRemove(key.toNativeUtf8(allocator: arena)),
    );
  }

  /// Removes every runtime annotation.
  void clear() => nativeAnnotationClear();

  static void _check(String text, String name, int maxBytes) {
    if (text.contains('\u0000')) {
      throw ArgumentError.value(text, name, 'contains a NUL character');
    }
    final bytes = utf8.encode(text).length;
    if (bytes > maxBytes) {
      throw ArgumentError.value(
        text,
        name,
        'is $bytes bytes of UTF-8; the limit is $maxBytes',
      );
    }
  }
}
