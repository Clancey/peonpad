# CMake build support

PeonPad's reusable build modules and Apple toolchains live here.

`toolchains/ios-arm64.cmake` is the physical-device toolchain. It always selects
the iPhoneOS SDK and arm64, uses a static-library try-compile mode, and disables
signing during dependency builds. Signing belongs to the later Xcode app target,
not to the C/C++ library build.

`PeonPadSDL3.cmake` is included only when `PEONPAD_ENABLE_SDL3=ON`. It verifies
and extracts the committed SDL3-family release archives into the build tree and
defines the direct foundation smoke and input-adapter targets. The lane is
isolated from `PEONPAD_ENABLE_ENGINE` until the staged Stratagus port is
complete.

`toolchains/xros-simulator-arm64.cmake` targets the native visionOS Simulator
SDK for SDL3-family configure/link evidence. It does not define a PeonPad
visionOS scene or application shell.
