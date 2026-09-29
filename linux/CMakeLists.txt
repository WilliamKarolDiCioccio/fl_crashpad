# fl_crashpad on Linux: nothing to compile — the library reaches the app
# through the Dart build hook. This file exists for the one thing a hook
# cannot ship: the crashpad_handler executable, installed at
# <bundle>/lib/crashpad_handler with its executable bit, where
# CrashpadHandler.defaultPath() looks for it.
cmake_minimum_required(VERSION 3.13)
project(fl_crashpad LANGUAGES NONE)

if(DEFINED FLUTTER_TARGET_PLATFORM)
  set(fl_crashpad_target "${FLUTTER_TARGET_PLATFORM}")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
  set(fl_crashpad_target "linux-arm64")
else()
  set(fl_crashpad_target "linux-x64")
endif()

set(fl_crashpad_handler_dir "${CMAKE_CURRENT_BINARY_DIR}/handler")
add_custom_target(fl_crashpad_handler ALL
  COMMAND "${CMAKE_COMMAND}"
    "-DFL_CRASHPAD_TARGET=${fl_crashpad_target}"
    "-DFL_CRASHPAD_LOCK=${CMAKE_CURRENT_SOURCE_DIR}/../native/artifacts.lock.cmake"
    "-DFL_CRASHPAD_OUT=${fl_crashpad_handler_dir}"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/../cmake/fetch_artifact.cmake"
  COMMENT "fl_crashpad: crashpad_handler for ${fl_crashpad_target}"
  VERBATIM)

# PROGRAMS, not the runner's install(FILES) for bundled libraries, which would
# install it 0644 — present, and unable to run.
install(PROGRAMS "${fl_crashpad_handler_dir}/crashpad_handler"
  DESTINATION lib COMPONENT Runtime)
install(FILES "${fl_crashpad_handler_dir}/crashpad_handler.rev"
  DESTINATION lib COMPONENT Runtime)

set(fl_crashpad_bundled_libraries "" PARENT_SCOPE)
