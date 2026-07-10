cmake_minimum_required(VERSION 3.27)

project(PeonPad
  VERSION 0.0.0
  DESCRIPTION "Apple-platform Stratagus/Wargus port"
  LANGUAGES C CXX
)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(PEONPAD_ENABLE_ENGINE
  "Configure staged Stratagus and Wargus sources"
  OFF
)

add_library(peonpad_toolchain_probe STATIC tests/toolchain_probe.cpp)
target_compile_features(peonpad_toolchain_probe PUBLIC cxx_std_17)

include(CTest)
if(BUILD_TESTING AND NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  add_test(
    NAME peonpad_script_guardrails
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/script-guardrails.sh"
  )
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  target_compile_definitions(peonpad_toolchain_probe PRIVATE
    PEONPAD_EXPECT_IOS=1
  )
else()
  target_compile_definitions(peonpad_toolchain_probe PRIVATE
    PEONPAD_EXPECT_MACOS=1
  )
endif()

if(PEONPAD_ENABLE_ENGINE)
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/engine/stratagus/CMakeLists.txt")
    message(FATAL_ERROR
      "PEONPAD_ENABLE_ENGINE requires staged Stratagus source at "
      "engine/stratagus. Complete and lock Goal 0 inputs first."
    )
  endif()
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/game/wargus/CMakeLists.txt")
    message(FATAL_ERROR
      "PEONPAD_ENABLE_ENGINE requires staged Wargus source at game/wargus. "
      "Complete and lock Goal 0 inputs first."
    )
  endif()

  if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    message(FATAL_ERROR
      "PEONPAD_ENABLE_ENGINE currently selects the proven macOS superbuild. "
      "Use the iOS library target added in the next phase for iPadOS."
    )
  endif()

  include(ExternalProject)

  if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
  endif()

  set(PEONPAD_MACOS_ARCHITECTURE "arm64" CACHE STRING
    "Architecture for the native baseline")
  set(PEONPAD_MACOS_DEPLOYMENT_TARGET "13.0" CACHE STRING
    "Minimum macOS version for the native baseline")

  set(PEONPAD_ENGINE_BINARY_DIR "${CMAKE_BINARY_DIR}/engine")
  set(PEONPAD_WARGUS_BINARY_DIR "${CMAKE_BINARY_DIR}/wargus")
  set(PEONPAD_STAGE_DIR "${CMAKE_BINARY_DIR}/stage")
  set(PEONPAD_STRATAGUS_BINARY
    "${PEONPAD_ENGINE_BINARY_DIR}/stratagus")

  ExternalProject_Add(peonpad_stratagus
    SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/engine/stratagus"
    BINARY_DIR "${PEONPAD_ENGINE_BINARY_DIR}"
    DOWNLOAD_COMMAND ""
    UPDATE_COMMAND ""
    PATCH_COMMAND ""
    CMAKE_ARGS
      "-DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}"
      "-DCMAKE_OSX_ARCHITECTURES:STRING=${PEONPAD_MACOS_ARCHITECTURE}"
      "-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=${PEONPAD_MACOS_DEPLOYMENT_TARGET}"
      "-DCMAKE_INSTALL_PREFIX:PATH=${PEONPAD_STAGE_DIR}"
      "-DBUILD_VENDORED_LUA:BOOL=ON"
      "-DBUILD_VENDORED_SDL:BOOL=ON"
      "-DBUILD_VENDORED_MEDIA_LIBS:BOOL=ON"
      "-DBUILD_TESTING:BOOL=OFF"
      "-DDOWNLOAD_FREEPATS:BOOL=OFF"
      "-DENABLE_DEV:BOOL=ON"
      "-DENABLE_DOC:BOOL=OFF"
      "-DWITH_OPENMP:BOOL=OFF"
      "-DWITH_STACKTRACE:BOOL=OFF"
    BUILD_COMMAND
      "${CMAKE_COMMAND}" --build <BINARY_DIR> --target stratagus --parallel
    INSTALL_COMMAND
      "${CMAKE_COMMAND}" -E copy <BINARY_DIR>/stratagus
      "${CMAKE_BINARY_DIR}/stratagus"
    BUILD_ALWAYS TRUE
    BUILD_BYPRODUCTS
      "${PEONPAD_STRATAGUS_BINARY}"
      "${CMAKE_BINARY_DIR}/stratagus"
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
  )

  ExternalProject_Add(peonpad_wargus
    DEPENDS peonpad_stratagus
    SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/game/wargus"
    BINARY_DIR "${PEONPAD_WARGUS_BINARY_DIR}"
    DOWNLOAD_COMMAND ""
    UPDATE_COMMAND ""
    PATCH_COMMAND ""
    CMAKE_ARGS
      "-DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}"
      "-DCMAKE_OSX_ARCHITECTURES:STRING=${PEONPAD_MACOS_ARCHITECTURE}"
      "-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=${PEONPAD_MACOS_DEPLOYMENT_TARGET}"
      "-DCMAKE_INSTALL_PREFIX:PATH=${PEONPAD_STAGE_DIR}"
      "-DSTRATAGUS:FILEPATH=${PEONPAD_STRATAGUS_BINARY}"
      "-DSTRATAGUS_INCLUDE_DIR:PATH=${CMAKE_CURRENT_SOURCE_DIR}/engine/stratagus/gameheaders"
      "-DENABLE_VENDORED_LIBS:BOOL=ON"
      "-DENABLE_STATIC:BOOL=OFF"
      "-DWITH_STORMLIB:BOOL=ON"
    BUILD_COMMAND
      "${CMAKE_COMMAND}" --build <BINARY_DIR>
      --target wargus wartool pudconvert --parallel
    INSTALL_COMMAND "${CMAKE_COMMAND}" -E true
    BUILD_ALWAYS TRUE
    BUILD_BYPRODUCTS
      "${PEONPAD_WARGUS_BINARY_DIR}/wargus"
      "${PEONPAD_WARGUS_BINARY_DIR}/wartool"
      "${PEONPAD_WARGUS_BINARY_DIR}/pudconvert"
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
  )

  set(PEONPAD_MACOS_APP "${CMAKE_BINARY_DIR}/PeonPad.app")
  set(PEONPAD_MACOS_APP_EXECUTABLE
    "${PEONPAD_MACOS_APP}/Contents/MacOS/PeonPad")
  add_custom_target(peonpad_macos_bundle
    COMMAND "${CMAKE_COMMAND}" -E make_directory
      "${PEONPAD_MACOS_APP}/Contents/MacOS"
    COMMAND "${CMAKE_COMMAND}" -E copy
      "${CMAKE_BINARY_DIR}/stratagus" "${PEONPAD_MACOS_APP_EXECUTABLE}"
    COMMAND "${CMAKE_COMMAND}" -E copy
      "${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/macos/Info.plist"
      "${PEONPAD_MACOS_APP}/Contents/Info.plist"
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/prepare-macos-bundle.sh"
      "${PEONPAD_MACOS_APP}"
    DEPENDS peonpad_stratagus
    VERBATIM
  )
  add_dependencies(peonpad_macos_bundle peonpad_stratagus)

  add_custom_target(peonpad_macos ALL
    DEPENDS peonpad_wargus peonpad_macos_bundle)
endif()
