# fl_crashpad on macOS: nothing to compile — the library reaches the app
# through the Dart build hook, as a framework flutter_tools makes of it. This
# pod exists for the one thing a hook cannot ship, the crashpad_handler
# executable, which it embeds in its own framework:
#
#   Contents/Frameworks/fl_crashpad.framework/Versions/A/Helpers/crashpad_handler
#
# Helpers inside a framework is where Apple expects a framework's helper
# tools, and what makes the eventual Developer ID signing a plain inside-out
# pass: the handler, then this framework, then the app. See the README.
Pod::Spec.new do |s|
  s.name             = 'fl_crashpad'
  s.version          = '0.1.0'
  s.summary          = 'Embeds crashpad_handler for fl_crashpad.'
  s.homepage         = 'https://github.com/WilliamKarolDiCioccio/fl_crashpad'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'William Karol Di Cioccio' => 'williamkarol.dicioccio@gmail.com' }
  s.source           = { :path => '.' }
  # One trivial source file, because CocoaPods makes no framework — and so no
  # place for Helpers/ — for a pod without sources.
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  s.script_phase = {
    :name => 'Embed crashpad_handler',
    :script => '"${PODS_TARGET_SRCROOT}/Scripts/embed_handler.sh"',
    :execution_position => :after_compile,
    :input_files => ['${PODS_TARGET_SRCROOT}/../native/artifacts.lock.txt'],
    :output_files => ['${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/crashpad_handler'],
  }
end
