# PeonPad iOS Simulator toolchain used for Designed-for-iPad compatibility.
#
# The app and all vendored dependencies use the iPhoneSimulator SDK. Listing
# both iOS platforms lets Xcode expose Vision Pro's "Designed for iPad" run
# destination; this project must not be used for physical-device builds.

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

set(CMAKE_OSX_SYSROOT iphonesimulator CACHE STRING
  "iPhoneSimulator SDK" FORCE)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING
  "Apple Silicon simulator architecture" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 16.0 CACHE STRING
  "Minimum iPadOS version" FORCE)

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH YES)
set(CMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS
  "iphoneos iphonesimulator")
set(CMAKE_XCODE_ATTRIBUTE_SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD YES)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)

set(PEONPAD_IOS_SIMULATOR_BUILD TRUE CACHE BOOL
  "PeonPad iOS Simulator compatibility build" FORCE)
