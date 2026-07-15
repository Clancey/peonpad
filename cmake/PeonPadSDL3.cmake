include(FetchContent)

if(PEONPAD_ENABLE_ENGINE)
  message(FATAL_ERROR
    "PEONPAD_ENABLE_SDL3 is an isolated foundation lane. The accepted "
    "PEONPAD_ENABLE_ENGINE SDL2 build remains the default until the engine "
    "video and audio ports are complete."
  )
endif()

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

set(_peonpad_sdl3_smoke_sources tests/sdl3_foundation_smoke.cpp)
if(APPLE)
  list(APPEND _peonpad_sdl3_smoke_sources
    platform/apple/PeonPadSDL3Window.mm
  )
endif()

add_executable(peonpad_sdl3_smoke ${_peonpad_sdl3_smoke_sources})
target_include_directories(peonpad_sdl3_smoke PRIVATE platform/apple)
target_compile_definitions(peonpad_sdl3_smoke PRIVATE
  PEONPAD_SDL3_IMAGE_FIXTURE="${peonpad_sdl3_SOURCE_DIR}/test/icon.png"
  PEONPAD_SDL3_AUDIO_FIXTURE="${peonpad_sdl3_mixer_SOURCE_DIR}/examples/spring.wav"
)
target_compile_features(peonpad_sdl3_smoke PRIVATE cxx_std_17)
target_link_libraries(peonpad_sdl3_smoke PRIVATE
  SDL3::SDL3
  SDL3_image::SDL3_image
  SDL3_mixer::SDL3_mixer
)

if(BUILD_TESTING AND
    NOT CMAKE_SYSTEM_NAME STREQUAL "iOS" AND
    NOT CMAKE_SYSTEM_NAME STREQUAL "visionOS")
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
endif()
