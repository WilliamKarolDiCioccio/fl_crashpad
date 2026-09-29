// Deliberately empty of behaviour. CocoaPods builds a framework only for a pod
// with at least one source file, and fl_crashpad.framework is where the
// handler is embedded; see fl_crashpad.podspec. The library itself arrives
// through the Dart build hook.
void fl_crashpad_pod_anchor(void) {}
