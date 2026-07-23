cmake_minimum_required(VERSION 3.27)

if(CMAKE_SYSTEM_NAME STREQUAL "visionOS" AND
    CMAKE_VERSION VERSION_LESS "3.28")
  message(FATAL_ERROR
    "Native visionOS configuration requires CMake 3.28 or newer because "
    "CMAKE_SYSTEM_NAME=visionOS was added in CMake 3.28. PeonPad's non-visionOS "
    "configurations remain compatible with CMake 3.27."
  )
endif()

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
option(PEONPAD_ENABLE_SDL3
  "Build the direct SDL3 lane (SDL2 remains the default)"
  OFF
)
option(PEONPAD_ENABLE_TABLETOP
  "Compile the visionOS live-tabletop bridge hooks into the engine (defines PEONPAD_TABLETOP for stratagus_lib so the sim thread publishes snapshots)"
  OFF
)

set(PEONPAD_VISIONOS OFF)
if(CMAKE_SYSTEM_NAME STREQUAL "visionOS")
  set(PEONPAD_VISIONOS ON)
endif()

add_library(peonpad_toolchain_probe STATIC tests/toolchain_probe.cpp)
target_compile_features(peonpad_toolchain_probe PUBLIC cxx_std_17)

include(CTest)
if(PEONPAD_ENABLE_SDL3)
  include(cmake/PeonPadSDL3.cmake)
endif()

# ── Tabletop bridge library (pure infrastructure, no Stratagus globals) ─────
# This target compiles without PEONPAD_TABLETOP so it carries no engine
# dependencies and can be linked into the standalone test binary.
add_library(peonpad_tabletop_bridge STATIC
  platform/bridge/PeonPadTabletopBridge.cpp
)
target_include_directories(peonpad_tabletop_bridge PUBLIC
  platform/bridge
)
target_compile_features(peonpad_tabletop_bridge PUBLIC cxx_std_17)

if(BUILD_TESTING AND
    NOT CMAKE_SYSTEM_NAME STREQUAL "iOS" AND
    NOT PEONPAD_VISIONOS)
  add_executable(peonpad_viewport_geometry_test
    tests/viewport_geometry_test.cpp
    platform/apple/ios/PeonPadViewportGeometry.cpp
  )
  target_include_directories(peonpad_viewport_geometry_test PRIVATE
    platform/apple/ios
  )
  target_compile_features(peonpad_viewport_geometry_test PRIVATE cxx_std_17)
  target_compile_definitions(peonpad_viewport_geometry_test PRIVATE NDEBUG)
  add_test(
    NAME peonpad_viewport_geometry_release
    COMMAND peonpad_viewport_geometry_test
  )

  add_executable(peonpad_input_intent_test
    tests/input_intent_test.cpp
    engine/stratagus/src/ui/controller_input.cpp
    engine/stratagus/src/ui/input_intent.cpp
    engine/stratagus/src/video/sdl_controller_adapter.cpp
    engine/stratagus/src/video/sdl_input_adapter.cpp
  )
  target_include_directories(peonpad_input_intent_test PRIVATE
    engine/stratagus/src/include
    engine/stratagus/third-party/SDL/include
    platform/apple/ios
  )
  target_compile_features(peonpad_input_intent_test PRIVATE cxx_std_17)
  target_compile_options(peonpad_input_intent_test PRIVATE
    "$<$<COMPILE_LANG_AND_ID:CXX,AppleClang,Clang,GNU>:-UNDEBUG>"
  )
  add_test(
    NAME peonpad_input_intent
    COMMAND peonpad_input_intent_test
  )
  add_test(
    NAME peonpad_input_assertions_active
    COMMAND peonpad_input_intent_test --verify-assertions
  )
  add_test(
    NAME peonpad_script_guardrails
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/script-guardrails.sh"
  )

  add_executable(peonpad_tabletop_bridge_test
    tests/tabletop_bridge_test.cpp
  )
  target_compile_features(peonpad_tabletop_bridge_test PRIVATE cxx_std_17)
  target_link_libraries(peonpad_tabletop_bridge_test PRIVATE
    peonpad_tabletop_bridge
  )
  add_test(NAME peonpad_tabletop_bridge
    COMMAND peonpad_tabletop_bridge_test)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  target_compile_definitions(peonpad_toolchain_probe PRIVATE
    PEONPAD_EXPECT_IOS=1
  )
elseif(PEONPAD_VISIONOS)
  target_compile_definitions(peonpad_toolchain_probe PRIVATE
    PEONPAD_EXPECT_VISIONOS=1
    PEONPAD_VISIONOS=1
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

  if(PEONPAD_VISIONOS AND NOT PEONPAD_ENABLE_SDL3)
    message(FATAL_ERROR
      "PEONPAD_ENABLE_ENGINE on visionOS requires "
      "PEONPAD_ENABLE_SDL3=ON."
    )
  elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS" AND NOT PEONPAD_ENABLE_SDL3)
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

  if(PEONPAD_ENABLE_SDL3)
    set(BUILD_VENDORED_LUA ON CACHE BOOL "" FORCE)
    set(BUILD_VENDORED_SDL OFF CACHE BOOL "" FORCE)
    set(BUILD_VENDORED_MEDIA_LIBS ON CACHE BOOL "" FORCE)
    set(DOWNLOAD_FREEPATS OFF CACHE BOOL "" FORCE)
    set(ENABLE_DEV ON CACHE BOOL "" FORCE)
    set(ENABLE_DOC OFF CACHE BOOL "" FORCE)
    set(WITH_OPENMP OFF CACHE BOOL "" FORCE)
    set(WITH_STACKTRACE OFF CACHE BOOL "" FORCE)
    set(PEONPAD_USE_SDL3 ON CACHE BOOL "" FORCE)
    set(PEONPAD_SDL3_COMPAT_INCLUDE_DIR
      "${CMAKE_CURRENT_SOURCE_DIR}/platform/sdl3/include"
      CACHE PATH "" FORCE)
    set(PEONPAD_SDL3_PLATFORM_DIR
      "${CMAKE_CURRENT_SOURCE_DIR}/platform/sdl3"
      CACHE PATH "" FORCE)
    set(PEONPAD_APPLE_PLATFORM_DIR
      "${CMAKE_CURRENT_SOURCE_DIR}/platform/apple"
      CACHE PATH "" FORCE)

    if(CMAKE_CROSSCOMPILING AND NOT STRATAGUS_HOST_TOLUAPP)
      set(_peonpad_host_tolua_binary
        "${CMAKE_BINARY_DIR}/host-tools/tolua/toluapp")
      ExternalProject_Add(peonpad_stratagus_host_tolua
        SOURCE_DIR
          "${CMAKE_CURRENT_SOURCE_DIR}/engine/stratagus/third-party/lua-5.1.5"
        BINARY_DIR "${CMAKE_BINARY_DIR}/host-tools/tolua"
        DOWNLOAD_COMMAND ""
        UPDATE_COMMAND ""
        PATCH_COMMAND ""
        CMAKE_ARGS
          "-DCMAKE_BUILD_TYPE:STRING=Release"
          "-DCMAKE_OSX_ARCHITECTURES:STRING=${CMAKE_HOST_SYSTEM_PROCESSOR}"
        BUILD_COMMAND
          "${CMAKE_COMMAND}" --build <BINARY_DIR> --target toluapp --parallel
        INSTALL_COMMAND ""
        BUILD_BYPRODUCTS "${_peonpad_host_tolua_binary}"
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
      )
      set(STRATAGUS_HOST_TOLUAPP "${_peonpad_host_tolua_binary}"
        CACHE FILEPATH "Native tolua++ generator used by cross builds" FORCE)
    endif()

    add_subdirectory(engine/stratagus "${PEONPAD_ENGINE_BINARY_DIR}")
    if(TARGET peonpad_stratagus_host_tolua)
      add_dependencies(stratagus_lib peonpad_stratagus_host_tolua)
    endif()

    # Engine-side tabletop bridge.
    #
    # The capture functions (peonpad_tabletop_publish_snapshot /
    # _drain_commands) read Stratagus globals (UnitManager, Map, Selected,
    # GameCycle…) and therefore need the engine's full include tree (SDL3, Lua,
    # third-party). Rather than re-derive that tree on a standalone target, the
    # bridge source is compiled directly into stratagus_lib so it inherits the
    # engine's directory-scoped include paths, and the extern "C" symbols the
    # mainloop.cpp #ifdef PEONPAD_TABLETOP block references resolve at link time.
    #
    # This is gated on PEONPAD_ENABLE_TABLETOP so other lanes (macOS baseline,
    # Designed-for-iPad) are unaffected: with the option OFF the engine neither
    # compiles the hooks nor the bridge capture.
    if(PEONPAD_ENABLE_TABLETOP)
      target_sources(stratagus_lib PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/platform/bridge/PeonPadTabletopBridge.cpp"
      )
      target_include_directories(stratagus_lib PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/platform/bridge"
      )
      # PEONPAD_TABLETOP on the whole library makes mainloop.cpp emit the
      # drain/publish hook calls and compiles the bridge's engine-capture path
      # (rather than the standalone stubs).
      target_compile_definitions(stratagus_lib PRIVATE PEONPAD_TABLETOP=1)
    endif()
  else()
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
  endif()

  if(NOT CMAKE_CROSSCOMPILING)
    if(PEONPAD_ENABLE_SDL3)
      set(_peonpad_wargus_engine_dependency stratagus)
    else()
      set(_peonpad_wargus_engine_dependency peonpad_stratagus)
    endif()
    ExternalProject_Add(peonpad_wargus
      DEPENDS ${_peonpad_wargus_engine_dependency}
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
  endif()

  if(NOT CMAKE_CROSSCOMPILING)
    set(PEONPAD_MACOS_APP "${CMAKE_BINARY_DIR}/PeonPad.app")
    set(PEONPAD_MACOS_APP_EXECUTABLE
      "${PEONPAD_MACOS_APP}/Contents/MacOS/PeonPad")
    if(PEONPAD_ENABLE_SDL3)
      set(_peonpad_macos_engine_source "$<TARGET_FILE:stratagus>")
      set(_peonpad_macos_engine_dependency stratagus)
    else()
      set(_peonpad_macos_engine_source "${CMAKE_BINARY_DIR}/stratagus")
      set(_peonpad_macos_engine_dependency peonpad_stratagus)
    endif()
    add_custom_target(peonpad_macos_bundle
      COMMAND "${CMAKE_COMMAND}" -E make_directory
        "${PEONPAD_MACOS_APP}/Contents/MacOS"
      COMMAND "${CMAKE_COMMAND}" -E copy
        "${_peonpad_macos_engine_source}" "${PEONPAD_MACOS_APP_EXECUTABLE}"
      COMMAND "${CMAKE_COMMAND}" -E copy
        "${CMAKE_CURRENT_SOURCE_DIR}/platform/apple/macos/Info.plist"
        "${PEONPAD_MACOS_APP}/Contents/Info.plist"
      COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/scripts/prepare-macos-bundle.sh"
        "${PEONPAD_MACOS_APP}"
      DEPENDS ${_peonpad_macos_engine_dependency}
      VERBATIM
    )

    add_custom_target(peonpad_macos ALL
      DEPENDS peonpad_wargus peonpad_macos_bundle)
  elseif(PEONPAD_ENABLE_SDL3)
    add_custom_target(peonpad_sdl3_engine ALL DEPENDS stratagus)
  endif()
endif()
