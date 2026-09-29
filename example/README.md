# fl_crashpad example

Starts Crashpad, sets a runtime annotation, crashes on purpose in each of the
ways `CrashpadTestCrash` names, and lists the reports — start it again after a
crash and the report is there. Open it to see what it holds: the exception and
where it happened, both kinds of annotation, the system and every module,
read by `lib/minidump.dart` — from the sanitised report, the same bytes that would be sent.

```sh
flutter run -d linux   # or windows, macos
```

Without a window, for CI:

```sh
flutter build linux
build/linux/x64/release/bundle/fl_crashpad_example --database=/tmp/db --crash=segfault
ls /tmp/db/pending
```
