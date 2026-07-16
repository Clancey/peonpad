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

`toolchains/xros-arm64.cmake` and `toolchains/xros-simulator-arm64.cmake` are
separate native visionOS 2.0+ device and Simulator configurations. Both set the
distinct `PEONPAD_VISIONOS` boundary; the former uses `xros`, while the latter
uses `xrsimulator`. See `docs/visionos-shell.md` for the native SDL3 smoke-shell
build, launch, inspection, and manual device-signing gates.
