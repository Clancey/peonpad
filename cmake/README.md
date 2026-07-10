# CMake build support

PeonPad's reusable build modules and Apple toolchains live here.

`toolchains/ios-arm64.cmake` is the physical-device toolchain. It always selects
the iPhoneOS SDK and arm64, uses a static-library try-compile mode, and disables
signing during dependency builds. Signing belongs to the later Xcode app target,
not to the C/C++ library build.
