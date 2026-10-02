# Security

fl_crashpad handles the most sensitive thing an app writes about its users: a
snapshot of the process at the moment it died. This is what the package does
to deserve that, what it cannot do, and how to tell us when it falls short.

## Reporting a vulnerability

Please report it privately, through **[GitHub's private vulnerability
reporting](https://github.com/WilliamKarolDiCioccio/fl_crashpad/security/advisories/new)**,
not in a public issue. Say what is exposed, on which platform, and how to
reproduce it; a minidump that shows it is welcome only if it holds nothing of
anybody's.

Fixes go into the latest release. A fix to the native half needs a native
release as well, which is slower — see [what the two releases
are](#what-you-are-running).

## What the package promises

- **Reports are sanitised before they can be read or sent.** Paths under the
  home directory, the account name, email addresses, credentials, secret-looking
  environment variables, IP addresses, and the secrets and folders the app
  names are masked inside the minidump, byte for byte, on the first start after
  a crash — before the handler is launched, so the handler only ever sends the
  cleaned copy — and again by `CrashReportDatabase` before it hands a report
  over. There is no API that returns or sends an unsanitised report while
  sanitising is on.
- **Nothing is sent without consent.** Consent is the user's answer, stored in
  the report database; it is `false` until something sets it, and a report
  written while it was `false` is kept, not sent. `requestUpload` sends one
  report because somebody asked to send that report.
- **Turning sanitising off is explicit.** It is `disableSanitization: true`,
  never a default and never a side effect of another option.
- **The package sends nothing anywhere of its own.** No telemetry, no default
  endpoint, no reporting SDK: reports go to the URL the app gives, or nowhere.

## What it cannot promise

**Sanitising removes what is recognisably about the user. It cannot know
whether something of theirs that looks like nothing in particular — a line of
a document, a value in a buffer — was on a native stack when the process
died.** The rules err on the side of taking too much, but a crash report is
still a crash report: an app should say in its privacy policy that they are
sent, and ask before sending them.

Not supported, and so not protected: the macOS App Sandbox (`start` refuses
with `CrashpadErrorCode.sandboxed`), and Android before 10.

## What you are running

The package has two halves, released separately.

- **The Dart package**, on pub.dev, versioned by `pubspec.yaml`.
- **The native half** — Crashpad's library, its handler and this package's
  shim — prebuilt for nine targets and published as a GitHub release
  (`native-v…`). It is pinned in `native/artifacts.lock.json`: the exact
  Crashpad revision and the revision of every dependency, and the SHA-256 of
  every archive. A build downloads the archive for its platform and **refuses
  it unless the digest matches**; a library and a handler from different
  Crashpad builds are refused at `start` (`revisionMismatch`), and a library
  speaking another ABI is not used at all.
- **Building it yourself** from the pinned sources, instead of downloading, is
  described in the README under *Building it yourself*.

Third-party licences are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
