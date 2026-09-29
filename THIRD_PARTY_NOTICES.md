# Third-party notices

fl_crashpad's own code is MIT-licensed (see `LICENSE`). The native half it
builds or downloads — the library the Dart code loads and the
`crashpad_handler` executable an app ships — is compiled from these projects,
whose licences travel inside every native archive under `LICENSES/`:

| Project | Licence | In |
| --- | --- | --- |
| [Crashpad](https://chromium.googlesource.com/crashpad/crashpad) | Apache License 2.0 | every target |
| [mini_chromium](https://chromium.googlesource.com/chromium/mini_chromium) | BSD 3-Clause | every target |
| [zlib](https://chromium.googlesource.com/chromium/src/third_party/zlib) | zlib License | Windows (Linux and macOS use the system's) |
| [linux-syscall-support](https://chromium.googlesource.com/linux-syscall-support) | BSD 3-Clause | Linux (headers only) |

An application that ships `crashpad_handler` redistributes Crashpad in binary
form, and the Apache License asks it to pass the licence on — an "open-source
licences" page or file in the app is the usual way.
