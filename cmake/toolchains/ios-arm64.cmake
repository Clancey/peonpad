# PeonPad physical-device iOS toolchain.
#
# Configure with an Xcode installation selected by xcode-select. The toolchain
# intentionally targets iphoneos/arm64 only; simulator slices are a separate
# build so device archives can never accidentally contain simulator code.

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

set(CMAKE_OSX_SYSROOT iphoneos CACHE STRING "iPhoneOS SDK" FORCE)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "iOS device architecture" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 16.0 CACHE STRING "Minimum iPadOS version" FORCE)

# Dependency feature probes must compile only. They cannot link or execute a
# host program while CMake is cross-compiling for a physical iOS device.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH YES)
set(PEONPAD_IOS_ENABLE_SIGNING OFF CACHE BOOL
  "Allow Xcode automatic signing for a connected personal device")
if(NOT PEONPAD_IOS_ENABLE_SIGNING)
  set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
  set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)
endif()

set(PEONPAD_IOS_DEVICE_BUILD TRUE CACHE BOOL
  "PeonPad physical iOS device build" FORCE)
