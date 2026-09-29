# Puts crashpad_handler (and on Windows crashpad_wer.dll) for one target in a
# directory of the build, from the same place the Dart build hook takes the
# library: $FL_CRASHPAD_ARTIFACTS_DIR if set, else the per-user cache, else a
# download verified against the lock.
#
# Run at build time, in script mode, by linux/ and windows/CMakeLists.txt:
#
#   cmake -DFL_CRASHPAD_TARGET=linux-x64 -DFL_CRASHPAD_LOCK=<artifacts.lock.cmake>
#         -DFL_CRASHPAD_OUT=<dir> -P fetch_artifact.cmake
#
# At build time and not at configure time because the plugin is configured
# before anything is built, and a cache the hook fills would not exist yet;
# and independent of the hook altogether, because nothing orders the two.
# The cache layout and the download's atomicity match
# lib/src/build/native_artifacts.dart, which is the reference.
cmake_minimum_required(VERSION 3.13)

include("${FL_CRASHPAD_LOCK}")
string(REPLACE "-" "_" target_variable "${FL_CRASHPAD_TARGET}")
set(expected_sha256 "${FL_CRASHPAD_SHA256_${target_variable}}")

if(FL_CRASHPAD_TARGET MATCHES "^windows")
  set(handler_name "crashpad_handler.exe")
  set(extra_files "crashpad_wer.dll")
else()
  set(handler_name "crashpad_handler")
  set(extra_files "")
endif()

if(DEFINED ENV{FL_CRASHPAD_ARTIFACTS_DIR} AND NOT "$ENV{FL_CRASHPAD_ARTIFACTS_DIR}" STREQUAL "")
  set(source "$ENV{FL_CRASHPAD_ARTIFACTS_DIR}")
  if(NOT EXISTS "${source}/bin/${handler_name}")
    message(FATAL_ERROR
      "fl_crashpad: FL_CRASHPAD_ARTIFACTS_DIR=${source} has no bin/${handler_name}")
  endif()
else()
  if(FL_CRASHPAD_TARGET MATCHES "^windows")
    file(TO_CMAKE_PATH "$ENV{USERPROFILE}/AppData/Local/fl_crashpad" cache_root)
  else()
    set(cache_root "$ENV{HOME}/.cache/fl_crashpad")
  endif()
  set(source "${cache_root}/${FL_CRASHPAD_ARTIFACTS_VERSION}/${FL_CRASHPAD_TARGET}")

  if(NOT EXISTS "${source}/.complete")
    if(expected_sha256 STREQUAL "")
      message(FATAL_ERROR
        "fl_crashpad: no ${FL_CRASHPAD_TARGET} build of native "
        "${FL_CRASHPAD_ARTIFACTS_VERSION} has been published yet. Build it "
        "from source with `dart run tool/build_native.dart --install` in the "
        "fl_crashpad package, or set FL_CRASHPAD_ARTIFACTS_DIR.")
    endif()
    set(archive "fl_crashpad-native-${FL_CRASHPAD_ARTIFACTS_VERSION}-${FL_CRASHPAD_TARGET}.tar.gz")
    string(RANDOM LENGTH 8 nonce)
    set(staging "${cache_root}/${FL_CRASHPAD_ARTIFACTS_VERSION}/.${FL_CRASHPAD_TARGET}-cmake-${nonce}")
    file(MAKE_DIRECTORY "${staging}")
    file(DOWNLOAD "${FL_CRASHPAD_RELEASE_BASE_URL}${archive}" "${staging}/${archive}"
      EXPECTED_HASH SHA256=${expected_sha256}
      STATUS status TLS_VERIFY ON)
    list(GET status 0 status_code)
    if(NOT status_code EQUAL 0)
      file(REMOVE_RECURSE "${staging}")
      message(FATAL_ERROR "fl_crashpad: downloading ${archive} failed: ${status}")
    endif()
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -E tar xzf "${archive}"
      WORKING_DIRECTORY "${staging}"
      RESULT_VARIABLE extracted)
    file(REMOVE "${staging}/${archive}")
    if(NOT extracted EQUAL 0 OR NOT EXISTS "${staging}/bin/${handler_name}")
      file(REMOVE_RECURSE "${staging}")
      message(FATAL_ERROR "fl_crashpad: ${archive} did not unpack as expected")
    endif()
    file(WRITE "${staging}/.complete" "${expected_sha256}")
    if(NOT EXISTS "${source}/.complete")
      if(EXISTS "${source}")
        file(REMOVE_RECURSE "${source}")
      endif()
      # Another build may win this race; its copy is as good as ours.
      file(RENAME "${staging}" "${source}" RESULT renamed)
    endif()
    if(EXISTS "${staging}")
      file(REMOVE_RECURSE "${staging}")
    endif()
  endif()
endif()

# file(COPY) keeps the source's permissions, which is the point on Linux.
file(MAKE_DIRECTORY "${FL_CRASHPAD_OUT}")
file(COPY "${source}/bin/${handler_name}" DESTINATION "${FL_CRASHPAD_OUT}")
foreach(extra ${extra_files} crashpad_handler.rev)
  if(EXISTS "${source}/bin/${extra}")
    file(COPY "${source}/bin/${extra}" DESTINATION "${FL_CRASHPAD_OUT}")
  endif()
endforeach()
