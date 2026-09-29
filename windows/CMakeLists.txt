# fl_crashpad on Windows: nothing to compile — the library reaches the app
# through the Dart build hook. This file exists for what a hook does not ship:
# crashpad_handler.exe and crashpad_wer.dll, placed beside the app's .exe,
# where CrashpadHandler.defaultPath() looks for them.
cmake_minimum_required(VERSION 3.13)
project(fl_crashpad LANGUAGES NONE)

if(CMAKE_GENERATOR_PLATFORM MATCHES "^(ARM64|arm64)$" OR
   (NOT CMAKE_GENERATOR_PLATFORM AND CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64)$"))
  set(fl_crashpad_target "windows-arm64")
else()
  set(fl_crashpad_target "windows-x64")
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

# The runner installs bundled libraries beside the executable; an executable
# needs no mode bit on Windows, so the handler can travel the same way.
set(fl_crashpad_bundled_libraries
  "${fl_crashpad_handler_dir}/crashpad_handler.exe"
  "${fl_crashpad_handler_dir}/crashpad_wer.dll"
  "${fl_crashpad_handler_dir}/crashpad_handler.rev"
  PARENT_SCOPE)
