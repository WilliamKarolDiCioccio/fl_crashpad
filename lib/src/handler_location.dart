import 'dart:io';

/// Where this package's build puts `crashpad_handler` inside an app bundle.
///
/// The build places it with each platform's own mechanism, never with the
/// Dart build hook, because a hook can ship libraries but not executables:
///
/// | | |
/// | --- | --- |
/// | Linux | `<bundle>/lib/crashpad_handler`, installed with its executable bit by the plugin's CMake. |
/// | Windows | `crashpad_handler.exe` beside the app's `.exe`, with `crashpad_wer.dll`. |
/// | macOS | `Contents/Frameworks/fl_crashpad.framework/Versions/A/Helpers/crashpad_handler`, embedded by the plugin's pod — where Apple expects a helper tool, so it can be signed inside-out with the rest of the app. |
abstract final class CrashpadHandler {
  /// The handler for the running app.
  static File defaultPath() => pathFor(
    os: Platform.operatingSystem,
    executable: Platform.resolvedExecutable,
  );

  /// Windows: `crashpad_wer.dll` beside the app, or null elsewhere.
  static File? defaultWerModule() => werModuleFor(
    os: Platform.operatingSystem,
    executable: Platform.resolvedExecutable,
  );

  /// The handler for an app whose executable is [executable] on [os]
  /// (as [Platform.operatingSystem] spells it).
  static File pathFor({required String os, required String executable}) {
    final separator = os == 'windows' ? r'\' : '/';
    final directory = _parent(executable, separator);
    return switch (os) {
      'linux' => File('$directory/lib/crashpad_handler'),
      'windows' => File('$directory\\crashpad_handler.exe'),
      // <App>.app/Contents/MacOS/<App> → <App>.app/Contents/Frameworks/...
      'macos' => File(
        '${_parent(directory, separator)}/Frameworks/fl_crashpad.framework/'
        'Versions/A/Helpers/crashpad_handler',
      ),
      _ => throw UnsupportedError('fl_crashpad has no handler for $os'),
    };
  }

  static File? werModuleFor({required String os, required String executable}) {
    if (os != 'windows') return null;
    return File('${_parent(executable, r'\')}\\crashpad_wer.dll');
  }

  static String _parent(String path, String separator) {
    // Windows paths may arrive with either separator.
    final normalised = separator == r'\' ? path.replaceAll('/', r'\') : path;
    final cut = normalised.lastIndexOf(separator);
    return cut <= 0 ? normalised : normalised.substring(0, cut);
  }
}
