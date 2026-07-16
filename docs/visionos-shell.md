# Native visionOS SDL3 smoke shell

PeonPad now has a native `xros`/`xrsimulator` application-shell foundation for
visionOS 2.0 or newer. It launches only the public SDL3 foundation payload. It
does **not** enable Stratagus, load a map, include game data, or provide playable
gameplay.

## Reproducible configurations

The device and Simulator slices are deliberately separate:

| Configuration | CMake system | SDK | Architecture | Mach-O platform |
| --- | --- | --- | --- | --- |
| `cmake/toolchains/xros-arm64.cmake` | `visionOS` | `xros` | arm64 | 11 |
| `cmake/toolchains/xros-simulator-arm64.cmake` | `visionOS` | `xrsimulator` | arm64 | 12 |

Both use a visionOS 2.0 deployment target and static-library try-compiles.
SDL 3.4.12, SDL_image 3.4.4, and SDL_mixer 3.2.4 still come from the exact
committed archives in `third_party/sdl3/sources`; configure and build require no
network access after those sources are present. Native visionOS configuration
requires CMake 3.28 or newer because that release introduced
`CMAKE_SYSTEM_NAME=visionOS`; macOS, iOS, and Designed-for-iPad lanes retain the
repository-wide CMake 3.27 minimum.

Run clean Release all-target builds with:

```sh
./scripts/build-visionos-shell.sh xrsimulator
./scripts/build-visionos-shell.sh xros
```

The scripts verify source hashes, remove their prior build tree, configure the
selected toolchain, build the complete default target, and inspect the generated
application with `scripts/verify-visionos-bundle.sh`. They do not select only
the smoke executable.

## Native shell boundary

`platform/apple/visionos` contains the native shell policy:

- `Info.plist.in` declares a window scene owned by SDL3's supported
  `SDLUIKitSceneDelegate`, `UIDeviceFamily = 7`, and no iPad-only full-screen or
  orientation keys.
- `PeonPadVisionOSShell.mm` verifies the SDL3 UIKit `UIWindow` and Metal view
  through public SDL window properties, then requests freeform visionOS window
  resizing with bounded minimum and maximum sizes.
- `PeonPadAssets.xcassets` is compiled into `Assets.car` using the existing
  original PeonPad icon. The copy/compiler bridge strips extended attributes
  before signing.

SDL3 retains application, scene, UIKit view, and Metal renderer ownership. The
shell does not use `SDL_syswm`, sdl2-compat, a forked SDL, SwiftUI, or private
Apple APIs.

The top-level `PEONPAD_VISIONOS` boundary remains distinct from iOS and macOS.
The toolchain probe requires `TARGET_OS_VISION=1`, `TARGET_OS_IOS=0`, and
`TARGET_OS_OSX=0`. The guarded `PEONPAD_ENABLE_ENGINE` and
`PEONPAD_ENABLE_SDL3` combination remains a hard error.

## Rendering and input transform

`PeonPadViewportGeometry` is the single shell transform. The shell reads
`SDL_GetWindowSafeArea`, converts that SDL point-space rectangle into inward-
rounded drawable-pixel insets using the current point/pixel dimensions, then
computes the largest exact-aspect 4:3 rectangle inside it. This produces
letterbox or pillarbox bars rather than stretching. The 640×480 public test card
is recomputed after window, drawable-pixel, display-scale, and safe-area changes.

The inverse transform rejects points in the bars and maps drawable pixels back
to logical coordinates. `PeonPadSDL3MapWindowPointToLogical` first converts
UIKit/SDL window points to Retina drawable pixels, then calls that same inverse.
The Release test runs with `-DNDEBUG` and uses explicit checks for default, wide,
tall, Retina/fractional display scale, asymmetric non-zero safe areas,
safe-area invalidation, repeated-resize, and bar-input cases:

```sh
./scripts/test-ios-viewport.sh
```

This verifies shell geometry and input mapping only. It is not live-map,
controller, eye/hand targeting, or gameplay evidence.

## Simulator install and launch

The discovery helper accepts only a device named Apple Vision Pro inside a
visionOS runtime. An override is validated by the same rule:

```sh
PEONPAD_VISION_SIMULATOR_UDID="SIMULATOR-UDID" \
  ./scripts/build-visionos-shell.sh xrsimulator --launch
```

Without an override, the newest available Vision Pro is selected. The launch
route boots it when needed, waits for boot completion, installs the ad-hoc
signed app, launches `org.peonpad.visionos`, waits three seconds, and verifies
the reported PID with simulator `launchctl procinfo`.

Optional screenshot evidence must stay outside the repository:

```sh
./scripts/build-visionos-shell.sh xrsimulator --launch \
  --screenshot /tmp/peonpad-visionos-smoke.png
```

On July 15, 2026, Xcode 26.6 built a clean arm64 platform-12 application against
the visionOS 26.5 Simulator SDK. It installed and launched on Apple Vision Pro /
visionOS 26.5, remained resident, logged
`PeonPad native visionOS smoke shell ready`, and displayed the public card
“SMOKE SHELL — NO GAMEPLAY.” The screenshot and generated application remain
local build evidence and are not committed.

## Physical-device signing gate

The command-line `xros` result is intentionally unsigned. The validated binary
is arm64, Mach-O platform 11, minimum visionOS 2.0. To create a device-signed
build, use Xcode's own account and provisioning support:

```sh
cmake --fresh -S . -B build/visionos-xcode -G Xcode \
  -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xros-arm64.cmake \
  -DPEONPAD_ENABLE_ENGINE=OFF \
  -DPEONPAD_ENABLE_SDL3=ON \
  -DPEONPAD_VISIONOS_ENABLE_SIGNING=ON \
  -DPEONPAD_VISIONOS_BUNDLE_IDENTIFIER="your.unique.bundle.identifier"

xcodebuild -project build/visionos-xcode/PeonPad.xcodeproj \
  -scheme peonpad_sdl3_smoke -configuration Release \
  -destination 'generic/platform=visionOS' \
  DEVELOPMENT_TEAM="YOUR_TEAM_ID" -allowProvisioningUpdates build
```

Credentials stay in Xcode. After Xcode has produced a development-signed app
with an embedded provisioning profile, explicitly pass the paired Vision Pro
identifier:

```sh
PEONPAD_VISIONOS_DEVICE_INSTALL=1 \
  ./scripts/install-visionos-device.sh \
  build/visionos-xcode/Release-xros/PeonPadVisionShell.app \
  "DEVICE-IDENTIFIER"
```

The install gate rejects simulator binaries, unsigned apps, missing profiles,
non-Vision-Pro destinations, and calls made without the explicit environment
acknowledgement. The currently discoverable physical Vision Pro was unavailable,
so signing, install, launch, and hardware acceptance remain external gates.

## Bundle and content checks

Bundle verification covers arm64 architecture, platform/minimum OS, scene
metadata, app icon catalog, public image/audio fixtures, system-framework
linkage, safe rpaths, and proprietary-content scans. The app has no bundled or
ignored Warcraft content and writes no source-adjacent state; SDL's pref path is
inside its application container.

RealityKit, SwiftUI ornaments, immersive spaces, ARKit or custom hand skeletons,
true 3D rendering, controller-remapping UX, and the guarded full SDL3 gameplay
engine are explicitly out of scope for this shell.
