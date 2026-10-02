import 'dart:io';

import 'sanitizer.dart';

/// Where reports go once written, if anywhere.
///
/// On desktop Crashpad's handler sends them; on Android and iOS this package
/// does, from Dart, in exactly the same shape — Crashpad's Android handler can
/// speak only plain http. Either way each report is POSTed as
/// `multipart/form-data`, with the minidump in
/// the `upload_file_minidump` field and every annotation as a field of its
/// own, which is the format Sentry, Backtrace, BugSplat, Socorro and most
/// self-hosted minidump collectors accept. Anything a particular backend wants
/// — a release name, an API key in the query string — is an annotation or a
/// part of [url], not a feature of this package.
class CrashpadUpload {
  const CrashpadUpload({
    required this.url,
    this.rateLimit = true,
    this.gzip = true,
    this.identifyClientViaUrl = true,
  });

  /// The endpoint reports are POSTed to.
  final Uri url;

  /// Crashpad's own limit of one upload per hour (`true`). Turn off only for
  /// a test server. Desktop only: on mobile, as for every report sent after
  /// sanitising, each upload is explicitly requested, which the limit exempts.
  final bool rateLimit;

  /// Compress the request body (`true`). Some collectors cannot read it.
  final bool gzip;

  /// Append the database's client id to [url] as `guid=` (`true`).
  final bool identifyClientViaUrl;
}

/// Everything [Crashpad.start] needs. Only [databaseDirectory] is required.
class CrashpadOptions {
  const CrashpadOptions({
    required this.databaseDirectory,
    this.handler,
    this.metricsDirectory,
    this.upload,
    this.uploadConsent,
    this.disableSanitization = false,
    this.sanitizer,
    this.annotations = const {},
    this.attachments = const [],
    this.periodicTasks = true,
    this.registerWerModule = true,
    this.handlerArguments = const [],
  });

  /// Where reports are written, created if needed. The application chooses:
  /// usually a folder under its application-support directory.
  final Directory databaseDirectory;

  /// The `crashpad_handler` executable. By default it is looked for where this
  /// package's build puts it inside the app bundle — see
  /// [CrashpadHandler.defaultPath]. Set it for a custom layout, or for a test
  /// run outside a bundle. Ignored on Android and iOS, which have no handler
  /// executable.
  final File? handler;

  /// Where the handler keeps its metrics, if at all (`null`: nowhere). Ignored
  /// on iOS.
  final Directory? metricsDirectory;

  /// Where reports are sent. `null` keeps every report in the database.
  ///
  /// On Android and iOS reports are sent by this package on the launch after
  /// the crash, in the background once [Crashpad.start] returns — see
  /// [Crashpad.sanitizationIdle] — whatever [disableSanitization] says.
  final CrashpadUpload? upload;

  /// Whether the user has agreed to reports being sent, or `null` (the
  /// default) to keep the answer they gave last time — which is `false`
  /// until somebody says otherwise.
  ///
  /// Kept in the database so it survives restarts and can be changed through
  /// [CrashReportDatabase.uploadConsent] without restarting Crashpad. Nothing
  /// is sent that nobody agreed to send. Pass what the user answered, not
  /// `true` because an endpoint is configured.
  final bool? uploadConsent;

  /// **Send and show reports exactly as the crashed process wrote them**
  /// (`false`).
  ///
  /// Off — the default — every report is sanitised before it can be read or
  /// sent. Each report is cleaned with [sanitizer] on the first start after the
  /// crash — before the handler is launched, so the handler only ever sends
  /// the cleaned one — and by [CrashReportDatabase] before it hands a report
  /// over. The price is timing: a report goes on the launch *after* the crash
  /// rather than from the dying process, because nothing of the app's can run
  /// in between. Reports a start does not get through in its half-second
  /// budget are finished in the background and sent on the handler's next
  /// pass, within fifteen minutes.
  ///
  /// Set, Crashpad sends each report straight from the crashed process,
  /// exactly as it was written: environment variables, the home directory,
  /// account names, credentials, whatever was on the stack. That is a choice
  /// about your users' data, which is why it is spelled as one rather than as
  /// a `false` beside the other options.
  final bool disableSanitization;

  /// What reports are cleaned with. `null` means [ReportSanitizer.forHost]:
  /// this machine's home directory and account name, and the app's own
  /// folder exempt. Pass one to add the app's own secrets or private folders.
  final ReportSanitizer? sanitizer;

  /// Process annotations, attached to every report. They are fixed at start —
  /// for values that change, use [Crashpad.annotations].
  ///
  /// Crashpad puts no size limit on these, unlike runtime annotations: they
  /// travel on the handler's command line.
  final Map<String, String> annotations;

  /// Files read at the moment of a crash and attached to its report — a log
  /// file, for instance. A file that does not exist then is skipped. Not
  /// supported on iOS, where they are ignored.
  final List<File> attachments;

  /// Let the handler prune old reports and retry failed uploads in the
  /// background (`true`). Ignored on iOS.
  final bool periodicTasks;

  /// Windows: register `crashpad_wer.dll` so that fast-fail crashes are
  /// reported too (`true`). Fast-fail is how Rust's `std::process::abort`,
  /// a panic that cannot unwind, `/GS` failures and the C runtime's own
  /// `abort()` end a process, and it skips the unhandled exception filter
  /// Crashpad otherwise relies on. Windows consults the module only if it is
  /// also listed in the registry, which [Crashpad.start] does itself, under
  /// the current user — no installer step, and nothing that needs elevation.
  /// It also clears `SEM_NOGPFAULTERRORBOX` from the error mode, without which
  /// Windows never invokes WER, and asks WER for no UI in its place. Ignored
  /// elsewhere.
  final bool registerWerModule;

  /// Extra handler arguments, passed through verbatim. Ignored on iOS.
  final List<String> handlerArguments;
}
