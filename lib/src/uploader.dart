// The upload this package makes itself, on the platforms where Crashpad's
// own cannot be trusted with it.
//
// **Why on Android and iOS the handler is never given a URL.** Crashpad's
// Android handler has only its `socket` transport, and that speaks plain http:
// BoringSSL is wired up for it only inside Chromium and Fuchsia
// (util/net/tls.gni), so it cannot reach an https endpoint, which is every
// endpoint. iOS could upload — its transport is NSURLSession — but doing it
// the same way costs nothing and gives mobile one upload path, the one proved
// on Android. And nothing native ever holding a URL is the simplest possible
// argument that nothing native sends a report unsanitised.
//
// **Byte for byte what Crashpad would have sent**
// (handler/crash_report_upload_thread.cc, UploadReport): the form fields are
// read out of the minidump by Crashpad's own
// BreakpadHTTPFormParametersFromMinidump, through the shim; then the files,
// in the key order of Crashpad's std::map — each attachment under its file
// name, and the minidump as `upload_file_minidump`, `<uuid>.dmp`; gzip when
// asked for; and `product`, `version` and `guid` appended to the URL
// when identifying the client. A 200 records the response body as the remote
// id, as Crashpad does. Anything else is a failed attempt, retried on a later
// start up to five times — the one retry policy Crashpad has, on iOS.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi/bindings.dart';
import 'native_call.dart';
import 'options.dart';
import 'report_store.dart';

/// Whether this package, rather than the handler, uploads reports here.
bool get uploadsFromDart => Platform.isAndroid || Platform.isIOS;

/// What the running process's [Crashpad.start] was told about uploads, so
/// that [CrashReportDatabase.requestUpload] can send a report at once
/// rather than on the next launch. Per isolate; null before start.
CrashpadUpload? activeUpload;

/// Crashpad's own timeout for one upload (kUploadReportTimeoutSeconds).
const Duration _timeout = Duration(seconds: 60);

/// Decides every pending report Crashpad would have decided, and sends the
/// ones that are to be sent: each report explicitly requested and, when
/// reports are not sanitised, every report once the user agreed. A report
/// that is to stay behind is moved to completed, as Crashpad's handler moves
/// one when uploads are off. A report still waiting to be sanitised is left
/// alone. Pass [only] to consider one report.
///
/// Never throws: a report that cannot be sent this time is tried again on a
/// later call.
Future<void> uploadPending(
  String database,
  CrashpadUpload upload, {
  String? only,
}) async {
  final settings = StoreSettings.read(database);
  final List<Map<String, Object?>> reports;
  try {
    reports = listNativeReports(database);
  } on Object {
    return;
  }
  for (final report in reports) {
    final id = report['id']! as String;
    if (only != null && id != only) continue;
    if (report['state'] != 'pending' || report['uploaded'] == true) continue;
    if (settings.sanitize && !isSanitized(database, id)) continue;

    final send =
        report['uploadExplicitlyRequested'] == true ||
        (!settings.sanitize && settings.uploadsEnabled);
    try {
      if (!send) {
        _record(database, id, uploadSkipped);
        continue;
      }
      final response = await _post(
        upload,
        id: id,
        minidump: File(report['path']! as String),
        attachments: Directory('$database/attachments/$id'),
      );
      _record(
        database,
        id,
        response == null ? uploadFailed : uploadSent,
        response: response,
      );
    } on Object {
      // The report stays pending, for the next start to try.
    }
  }
}

/// Sends one report, and returns the server's answer, or null for anything
/// Crashpad would have counted a failure.
Future<String?> _post(
  CrashpadUpload upload, {
  required String id,
  required File minidump,
  required Directory attachments,
}) async {
  final fields = uploadFields(minidump.path);

  final boundary = _boundary();
  final body = BytesBuilder(copy: false);
  void text(String value) => body.add(utf8.encode(value));
  void part(String name, {String? filename}) {
    text('--$boundary\r\n');
    text('Content-Disposition: form-data; name="${_mime(name)}"');
    if (filename != null) {
      text('; filename="$filename"\r\n');
      text('Content-Type: application/octet-stream');
    }
    text('\r\n\r\n');
  }

  const minidumpKey = 'upload_file_minidump';
  final keys = fields.keys.where((k) => k != minidumpKey).toList()..sort();
  for (final key in keys) {
    part(key);
    text('${fields[key]}\r\n');
  }
  // Keyed by part name, the minidump among the attachments: one sorted map.
  final files = <String, (String, File)>{
    if (attachments.existsSync())
      for (final file in attachments.listSync().whereType<File>())
        file.uri.pathSegments.last: (file.uri.pathSegments.last, file),
    minidumpKey: ('$id.dmp', minidump),
  };
  for (final key in files.keys.toList()..sort()) {
    final (filename, file) = files[key]!;
    part(key, filename: filename);
    body.add(file.readAsBytesSync());
    text('\r\n');
  }
  text('--$boundary--\r\n');

  var url = upload.url.toString();
  if (upload.identifyClientViaUrl) {
    for (final (key, name) in const [
      ('prod', 'product'),
      ('ver', 'version'),
      ('guid', 'guid'),
    ]) {
      final value = fields[key];
      if (value == null) continue;
      url += '${url.contains('?') ? '&' : '?'}$name=${_urlEncode(value)}';
    }
  }

  var bytes = body.takeBytes();
  final client = HttpClient()..connectionTimeout = _timeout;
  try {
    final request = await client.postUrl(Uri.parse(url)).timeout(_timeout);
    request.headers.contentType = ContentType(
      'multipart',
      'form-data',
      parameters: {'boundary': boundary},
    );
    if (upload.gzip) {
      bytes = Uint8List.fromList(gzip.encode(bytes));
      request.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
    }
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(_timeout);
    final answer = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_timeout);
    return response.statusCode == HttpStatus.ok ? answer : null;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// The form fields Crashpad's uploader would send with [minidumpPath].
Map<String, String> uploadFields(String minidumpPath) {
  final json = callNative((arena, error) {
    final out = arena<Pointer<Utf8>>();
    final status = nativeReportUploadFields(
      minidumpPath.toNativeUtf8(allocator: arena),
      out,
      error,
    );
    if (status != statusOk) return (status, '{}');
    try {
      return (status, out.value.toDartString());
    } finally {
      nativeFree(out.value.cast());
    }
  });
  return (jsonDecode(json) as Map<String, Object?>).cast<String, String>();
}

void _record(String database, String id, int outcome, {String? response}) =>
    callNative((arena, error) {
      return (
        nativeDatabaseRecordUpload(
          database.toNativeUtf8(allocator: arena),
          id.toNativeUtf8(allocator: arena),
          outcome,
          response == null ? nullptr : response.toNativeUtf8(allocator: arena),
          error,
        ),
        null,
      );
    });

/// Crashpad's boundary shape (HTTPMultipartBuilder::GenerateBoundaryString).
String _boundary() {
  const alphabet =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  final random = Random.secure();
  final tail = List.generate(
    32,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
  return '---MultipartBoundary-$tail---';
}

/// A part name inside its quoted header parameter, escaped as Crashpad's
/// EncodeMIMEField does. (A file name goes in as it is, as it does there.)
String _mime(String value) => value
    .replaceAll('%', '%25')
    .replaceAll('"', '%22')
    .replaceAll('\r', '%0d')
    .replaceAll('\n', '%0a');

/// Crashpad's URLEncode: everything but unreserved characters as %XX.
String _urlEncode(String value) {
  final out = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final c = String.fromCharCode(byte);
    if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c)) {
      out.write(c);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}
