include(FetchContent)

set(FETCHCONTENT_TRY_FIND_PACKAGE_MODE NEVER)
set(FETCHCONTENT_UPDATES_DISCONNECTED ON)

if(APPLE)
  enable_language(OBJCXX)
endif()

set(_peonpad_sdl3_sources "${CMAKE_CURRENT_LIST_DIR}/../third_party/sdl3/sources")

set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL OFF CACHE BOOL "" FORCE)

FetchContent_Declare(peonpad_sdl3
  URL "${_peonpad_sdl3_sources}/SDL-release-3.4.12.tar.gz"
  URL_HASH
    "SHA256=b68381f06a7580e63400b3b6eb547ec57d8c3ebde70f9f40e0aba530ba05da27"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(peonpad_sdl3)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_INSTALL OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_SAMPLES OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_TESTS OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_VENDORED OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_STRICT ON CACHE BOOL "" FORCE)
set(SDLIMAGE_AVIF OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_JXL OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_PNG_LIBPNG OFF CACHE BOOL "" FORCE)
set(SDLIMAGE_WEBP OFF CACHE BOOL "" FORCE)

FetchContent_Declare(peonpad_sdl3_image
  URL "${_peonpad_sdl3_sources}/SDL_image-release-3.4.4.tar.gz"
  URL_HASH
    "SHA256=b0c11bbde540e26d1cedf31174349fe6ab67e57658efe22e16e75172859c817d"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(peonpad_sdl3_image)

set(SDLMIXER_INSTALL OFF CACHE BOOL "" FORCE)
set(SDLMIXER_TESTS OFF CACHE BOOL "" FORCE)
set(SDLMIXER_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDLMIXER_VENDORED OFF CACHE BOOL "" FORCE)
set(SDLMIXER_STRICT ON CACHE BOOL "" FORCE)
set(SDLMIXER_FLAC_LIBFLAC OFF CACHE BOOL "" FORCE)
set(SDLMIXER_GME OFF CACHE BOOL "" FORCE)
set(SDLMIXER_MOD OFF CACHE BOOL "" FORCE)
set(SDLMIXER_MP3_MPG123 OFF CACHE BOOL "" FORCE)
set(SDLMIXER_MIDI OFF CACHE BOOL "" FORCE)
set(SDLMIXER_OPUS OFF CACHE BOOL "" FORCE)
set(SDLMIXER_VORBIS_VORBISFILE OFF CACHE BOOL "" FORCE)
set(SDLMIXER_VORBIS_TREMOR OFF CACHE BOOL "" FORCE)
set(SDLMIXER_WAVPACK OFF CACHE BOOL "" FORCE)

FetchContent_Declare(peonpad_sdl3_mixer
  URL "${_peonpad_sdl3_sources}/SDL_mixer-release-3.2.4.tar.gz"
  URL_HASH
    "SHA256=f2ea848ccdf2f394cd4973ee0f6c482e04511044695cccfd46bab6dcd7f780aa"
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(peonpad_sdl3_mixer)

add_library(peonpad_sdl3_input_adapter STATIC
  platform/sdl3/PeonPadSDL3InputAdapter.cpp
)
target_include_directories(peonpad_sdl3_input_adapter PUBLIC
  platform/sdl3
  engine/stratagus/src/include
)
target_link_libraries(peonpad_sdl3_input_adapter PUBLIC SDL3::SDL3)
target_compile_features(peonpad_sdl3_input_adapter PUBLIC cxx_std_17)

add_library(peonpad_sdl3_mixer_adapter STATIC
  platform/sdl3/PeonPadSDL3MixerAdapter.cpp
)
target_include_directories(peonpad_sdl3_mixer_adapter PUBLIC
  platform/sdl3/include
)
target_link_libraries(peonpad_sdl3_mixer_adapter PUBLIC
  SDL3::SDL3
  SDL3_mixer::SDL3_mixer
)
target_compile_features(peonpad_sdl3_mixer_adapter PUBLIC cxx_std_17)

set(_peonpad_sdl3_smoke_sources tests/sdl3_foundation_smoke.cpp)
if(APPLE)
  list(APPEND _peonpad_sdl3_smoke_sources
    platform/apple/PeonPadSDL3Window.mm
    platform/apple/ios/PeonPadViewportGeometry.cpp
  )
endif()
if(PEONPAD_VISIONOS)
  list(APPEND _peonpad_sdl3_smoke_sources
    platform/apple/visionos/PeonPadVisionOSShell.mm
    "${peonpad_sdl3_SOURCE_DIR}/test/icon.png"
    "${peonpad_sdl3_mixer_SOURCE_DIR}/examples/spring.wav"
  )
  set_source_files_properties(
    "${peonpad_sdl3_SOURCE_DIR}/test/icon.png"
    "${peonpad_sdl3_mixer_SOURCE_DIR}/examples/spring.wav"
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources
  )
endif()

add_executable(peonpad_sdl3_smoke ${_peonpad_sdl3_smoke_sources})
target_include_directories(peonpad_sdl3_smoke PRIVATE
  platform/apple
  platform/apple/ios
  platform/apple/visionos
)
if(PEONPAD_VISIONOS)
  set(PEONPAD_VISIONOS_BUNDLE_IDENTIFIER "org.peonpad.visionos"
    CACHE STRING "Bundle identifier for the native visionOS smoke shell")
  if(PEONPAD_VISIONOS_SIMULATOR_BUILD)
    set(PEONPAD_VISIONOS_SUPPORTED_PLATFORM XRSimulator)
  else()
    set(PEONPAD_VISIONOS_SUPPORTED_PLATFORM XROS)
  endif()
  target_compile_definitions(peonpad_sdl3_smoke PRIVATE
    PEONPAD_SDL3_AUDIO_FIXTURE="spring.wav"
    PEONPAD_SDL3_BUNDLED_FIXTURES=1
    PEONPAD_SDL3_IMAGE_FIXTURE="icon.png"
    PEONPAD_VISIONOS=1
    PEONPAD_VISIONOS_BUNDLE_IDENTIFIER="${PEONPAD_VISIONOS_BUNDLE_IDENTIFIER}"
  )
  set_target_properties(peonpad_sdl3_smoke PROPERTIES
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST
      "${CMAKE_CURRENT_LIST_DIR}/../platform/apple/visionos/Info.plist.in"
    OUTPUT_NAME PeonPadVisionShell
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER
      "${PEONPAD_VISIONOS_BUNDLE_IDENTIFIER}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY 7
  )
  if(PEONPAD_VISIONOS_ENABLE_SIGNING)
    set_target_properties(peonpad_sdl3_smoke PROPERTIES
      XCODE_ATTRIBUTE_CODE_SIGN_STYLE Automatic
    )
  endif()
  add_custom_command(TARGET peonpad_sdl3_smoke POST_BUILD
    COMMAND
      "${CMAKE_CURRENT_LIST_DIR}/../platform/apple/visionos/compile-bundle-assets.sh"
      "${CMAKE_OSX_SYSROOT}"
      "${CMAKE_COMMAND}"
      "$<TARGET_BUNDLE_DIR:peonpad_sdl3_smoke>"
      "${CMAKE_CURRENT_LIST_DIR}/../platform/apple/visionos/PeonPadAssets.xcassets"
      "${CMAKE_CURRENT_LIST_DIR}/../platform/apple/ios/PeonPadAssets.xcassets/AppIcon.appiconset/PeonPadIcon.png"
      "${CMAKE_CURRENT_BINARY_DIR}/visionos-assets"
    VERBATIM
  )
else()
  target_compile_definitions(peonpad_sdl3_smoke PRIVATE
    PEONPAD_SDL3_AUDIO_FIXTURE="${peonpad_sdl3_mixer_SOURCE_DIR}/examples/spring.wav"
    PEONPAD_SDL3_IMAGE_FIXTURE="${peonpad_sdl3_SOURCE_DIR}/test/icon.png"
  )
endif()
target_compile_features(peonpad_sdl3_smoke PRIVATE cxx_std_17)
target_link_libraries(peonpad_sdl3_smoke PRIVATE
  SDL3::SDL3
  SDL3_image::SDL3_image
  SDL3_mixer::SDL3_mixer
)

if(BUILD_TESTING AND
    NOT CMAKE_SYSTEM_NAME STREQUAL "iOS" AND
    NOT PEONPAD_VISIONOS)
  add_executable(peonpad_sdl3_input_adapter_test
    tests/sdl3_input_adapter_test.cpp
    engine/stratagus/src/ui/controller_input.cpp
    engine/stratagus/src/ui/input_intent.cpp
  )
  target_include_directories(peonpad_sdl3_input_adapter_test PRIVATE
    engine/stratagus/src/include
  )
  target_compile_features(peonpad_sdl3_input_adapter_test PRIVATE cxx_std_17)
  target_compile_options(peonpad_sdl3_input_adapter_test PRIVATE
    "$<$<COMPILE_LANG_AND_ID:CXX,AppleClang,Clang,GNU>:-UNDEBUG>"
  )
  target_link_libraries(peonpad_sdl3_input_adapter_test PRIVATE
    peonpad_sdl3_input_adapter
  )
  add_test(NAME peonpad_sdl3_input_adapter
    COMMAND peonpad_sdl3_input_adapter_test)
  add_test(NAME peonpad_sdl3_input_assertions_active
    COMMAND peonpad_sdl3_input_adapter_test --verify-assertions)
  add_test(NAME peonpad_sdl3_foundation
    COMMAND peonpad_sdl3_smoke --headless)

  add_executable(peonpad_sdl3_mixer_adapter_test
    tests/sdl3_mixer_adapter_test.cpp
  )
  target_compile_features(peonpad_sdl3_mixer_adapter_test PRIVATE cxx_std_17)
  target_compile_definitions(peonpad_sdl3_mixer_adapter_test PRIVATE NDEBUG)
  target_link_libraries(peonpad_sdl3_mixer_adapter_test PRIVATE
    peonpad_sdl3_mixer_adapter
  )
  add_test(NAME peonpad_sdl3_mixer_adapter
    COMMAND peonpad_sdl3_mixer_adapter_test)
  add_test(NAME peonpad_sdl3_mixer_assertions_inactive
    COMMAND peonpad_sdl3_mixer_adapter_test --verify-assertions)
  set_tests_properties(peonpad_sdl3_mixer_assertions_inactive PROPERTIES
    WILL_FAIL TRUE)
endif()
