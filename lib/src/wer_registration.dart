// Windows: the registry value that lets Windows Error Reporting load
// crashpad_wer.dll.
//
// **Why this is needed at all.** Crashpad catches a crash on Windows through
// the process's unhandled-exception filter, and a fast-fail skips it: a `/GS`
// stack-cookie check, the C runtime's invalid-parameter handler and `abort()`,
// heap corruption Windows detects, a Rust abort. Those go straight to WER,
// which will hand them to Crashpad's helper module only if the module was both
// registered by the process (`WerRegisterRuntimeExceptionModule`, which the
// shim does) **and** listed in the registry under
// `RuntimeExceptionHelperModules`, as a DWORD value named by its full path.
//
// **Why the package writes it rather than the installer.** HKCU needs no
// elevation, so the app can do it itself on every start — which covers a zip,
// a portable copy, a developer's `flutter run`, and an app moved after install,
// none of which an installer step reaches. Chromium's per-user installs use
// HKCU for the same value. It is written every start rather than checked
// first: one small idempotent write, and never stale.
//
// **What it cannot do** is remove the value when the app is uninstalled. A
// value naming a DLL that is gone is inert — WER fails to load it and moves
// on — and an installer that wants to tidy it can still add it with
// `uninsdeletevalue`, which the README shows.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const String _subKey =
    r'Software\Microsoft\Windows\Windows Error Reporting'
    r'\RuntimeExceptionHelperModules';

// (HKEY)(ULONG_PTR)(LONG)0x80000001, sign-extended to 64 bits.
const int _hkeyCurrentUser = -0x7fffffff;
const int _keySetValue = 0x0002;
const int _regDword = 4;
const int _errorSuccess = 0;

typedef _RegCreateKeyExWNative =
    Int32 Function(
      Pointer<Void> key,
      Pointer<Utf16> subKey,
      Uint32 reserved,
      Pointer<Utf16> className,
      Uint32 options,
      Uint32 access,
      Pointer<Void> security,
      Pointer<Pointer<Void>> result,
      Pointer<Uint32> disposition,
    );
typedef _RegCreateKeyExW =
    int Function(
      Pointer<Void> key,
      Pointer<Utf16> subKey,
      int reserved,
      Pointer<Utf16> className,
      int options,
      int access,
      Pointer<Void> security,
      Pointer<Pointer<Void>> result,
      Pointer<Uint32> disposition,
    );
typedef _RegSetValueExWNative =
    Int32 Function(
      Pointer<Void> key,
      Pointer<Utf16> name,
      Uint32 reserved,
      Uint32 type,
      Pointer<Uint8> data,
      Uint32 size,
    );
typedef _RegSetValueExW =
    int Function(
      Pointer<Void> key,
      Pointer<Utf16> name,
      int reserved,
      int type,
      Pointer<Uint8> data,
      int size,
    );
typedef _RegCloseKeyNative = Int32 Function(Pointer<Void> key);
typedef _RegCloseKey = int Function(Pointer<Void> key);

/// Lists [modulePath] under HKCU's `RuntimeExceptionHelperModules`, so that
/// WER loads it for a fast-fail crash. Windows only; a no-op elsewhere.
///
/// Returns whether the value was written. Never throws: a registry that
/// refuses — a policy, a locked-down profile — costs the fast-fail crashes
/// and nothing else, which is not worth failing `start` over.
bool registerWerModuleInRegistry(String modulePath) {
  if (!Platform.isWindows) return false;
  try {
    final advapi = DynamicLibrary.open('advapi32.dll');
    final create = advapi
        .lookupFunction<_RegCreateKeyExWNative, _RegCreateKeyExW>(
          'RegCreateKeyExW',
        );
    final set = advapi.lookupFunction<_RegSetValueExWNative, _RegSetValueExW>(
      'RegSetValueExW',
    );
    final close = advapi.lookupFunction<_RegCloseKeyNative, _RegCloseKey>(
      'RegCloseKey',
    );
    return using((arena) {
      final key = arena<Pointer<Void>>();
      final status = create(
        Pointer.fromAddress(_hkeyCurrentUser),
        _subKey.toNativeUtf16(allocator: arena),
        0,
        nullptr,
        0,
        _keySetValue,
        nullptr,
        key,
        nullptr,
      );
      if (status != _errorSuccess) return false;
      try {
        final zero = arena<Uint32>()..value = 0;
        return set(
              key.value,
              modulePath.toNativeUtf16(allocator: arena),
              0,
              _regDword,
              zero.cast(),
              sizeOf<Uint32>(),
            ) ==
            _errorSuccess;
      } finally {
        close(key.value);
      }
    });
  } on Object {
    return false;
  }
}
