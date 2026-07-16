# Native PeonPad visionOS Simulator toolchain.
#
# This configuration always selects xrsimulator/arm64. Device builds use the
# separate xros-arm64.cmake toolchain so the two slices cannot be mixed.

set(CMAKE_SYSTEM_NAME visionOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

set(CMAKE_OSX_SYSROOT xrsimulator CACHE STRING
  "visionOS Simulator SDK" FORCE)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING
  "Apple Silicon simulator architecture" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 2.0 CACHE STRING
  "Minimum visionOS version for the SDL3 foundation" FORCE)

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH YES)
set(CMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "xrsimulator")
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)

set(PEONPAD_VISIONOS TRUE CACHE BOOL
  "PeonPad native visionOS platform boundary" FORCE)
set(PEONPAD_VISIONOS_SIMULATOR_BUILD TRUE CACHE BOOL
  "PeonPad native visionOS Simulator build" FORCE)
