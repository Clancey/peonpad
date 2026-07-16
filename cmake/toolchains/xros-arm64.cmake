# Native PeonPad visionOS physical-device toolchain.
#
# This configuration always selects xros/arm64. Signing is disabled by default
# for reproducible command-line dependency builds and must be explicitly enabled
# in an Xcode build with a local development team.

if(CMAKE_VERSION VERSION_LESS "3.28")
  message(FATAL_ERROR
    "The PeonPad xros toolchain requires CMake 3.28 or newer because "
    "CMAKE_SYSTEM_NAME=visionOS is unavailable in CMake 3.27. Non-visionOS "
    "PeonPad configurations continue to support CMake 3.27.")
endif()

set(CMAKE_SYSTEM_NAME visionOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

set(CMAKE_OSX_SYSROOT xros CACHE STRING "visionOS device SDK" FORCE)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING
  "visionOS device architecture" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 2.0 CACHE STRING
  "Minimum visionOS version" FORCE)

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH YES)
set(CMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "xros")
set(PEONPAD_VISIONOS_ENABLE_SIGNING OFF CACHE BOOL
  "Allow Xcode automatic signing for a connected Apple Vision Pro")
if(NOT PEONPAD_VISIONOS_ENABLE_SIGNING)
  set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
  set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)
endif()

set(PEONPAD_VISIONOS TRUE CACHE BOOL
  "PeonPad native visionOS platform boundary" FORCE)
set(PEONPAD_VISIONOS_DEVICE_BUILD TRUE CACHE BOOL
  "PeonPad native visionOS physical-device build" FORCE)
