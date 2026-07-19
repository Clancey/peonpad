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

## Automated acceptance

`accept-visionos.sh` is the noninteractive acceptance entry point. It composes
the existing clean build, source-lock, bundle, public preflight, compatibility,
viewport/input, and script-guardrail checks rather than reproducing them:

```sh
./scripts/accept-visionos.sh xrsimulator
./scripts/accept-visionos.sh xros
./scripts/accept-visionos.sh all
```

Every lane is Release and builds the complete default/all target. The simulator
lane selects only an available Apple Vision Pro on a visionOS runtime, preferring
the newest booted match deterministically. It boots when necessary, installs the
freshly compared bundle, launches with the previous process terminated, requires
three parsed residency checks, captures process-scoped logs and a fresh
screenshot, requires the exact stable `PEONPAD_VISIONOS_READY=1` token, scans
first-party output for fatal/SDL/Metal/render/viewport/safe-area failures, then
terminates, relaunches with a different PID, and repeats the lifecycle checks.
Each log window starts immediately before its launch, remains PID-scoped, and
excludes only explicitly identified unrelated simulator messages.

The xros lane builds without signing and requires platform 11, arm64, visionOS
2.0 or newer, the selected SDK, valid scene/icon/resource/linkage/rpath
metadata, no simulator slice, no signing artifacts, and a failing strict
signature verification. It does not sign, install, or launch on hardware.

`all` additionally performs a fresh Release SDL3 host configuration and complete
default build, runs every configured CTest (currently 7/7), the direct
`-DNDEBUG` viewport/input checks, public preflight, and Designed-for-iPad
compatibility preflight. Before any configure or build, acceptance rejects
staged, unstaged, or untracked source changes. Ignored generated build paths
remain allowed, and explicit evidence paths must remain outside the repository.
Any failed build, test, lifecycle check, log scan, cleanup, or result write
fails the command immediately.

The command writes a transactional JSON result outside the repository. It
validates conversion output before an atomic move, validates the installed JSON
again, and cannot pass without a fresh final result. It records the commit,
clean source state, Xcode/CMake/SDK versions, Release/all-target scope, lane and
bundle metadata, selected simulator model/runtime/UDID, both fresh PIDs,
residency and test counts, evidence paths, warnings, and pass/fail. Evidence
uses a fresh temporary directory and is deleted by default:

```sh
./scripts/accept-visionos.sh all \
  --keep-evidence \
  --evidence-dir /tmp/peonpad-visionos-evidence \
  --result /tmp/peonpad-visionos-result.json
```

Both explicit paths must be outside the checkout; existing evidence and result
destinations are rejected so stale output cannot satisfy acceptance.
`--keep-evidence` retains local logs and the screenshot for inspection. The JSON
result is retained regardless. The generic acceptance script does not assert
the smoke-card wording or a pixel hash, so the same command remains the gate
when the gameplay payload replaces the current shell.

## Native shell boundary

`platform/apple/visionos` contains the native shell policy:

- `Info.plist.in` declares a window scene owned by SDL3's supported
  `SDLUIKitSceneDelegate`, `UIDeviceFamily = 7`, and no iPad-only full-screen or
  orientation keys.
- `PeonPadVisionOSShell.mm` verifies the SDL3 UIKit `UIWindow` and Metal view
  through public SDL window properties, then requests freeform visionOS window
  resizing with bounded minimum and maximum sizes.
- `PeonPadAssets.xcassets` is compiled into `Assets.car` using the existing
  original PeonPad icon. Verification requires the bundle's `AppIcon`
  declaration and inspects the compiled catalog for that solid image stack. The
  copy/compiler bridge strips extended attributes before signing.

SDL3 retains application, scene, UIKit view, and Metal renderer ownership. The
shell does not use `SDL_syswm`, sdl2-compat, a forked SDL, SwiftUI, or private
Apple APIs.

The top-level `PEONPAD_VISIONOS` boundary remains distinct from iOS and macOS.
The toolchain probe requires `TARGET_OS_VISION=1`, `TARGET_OS_IOS=0`, and
`TARGET_OS_OSX=0`. `PEONPAD_ENABLE_ENGINE=ON` and
`PEONPAD_ENABLE_SDL3=ON` now compile and link the complete engine for both
xrsimulator and xros. That engine artifact is not copied into or launched by
the smoke-shell application.

## Engine handoff contract

The next packaging layer must place a complete redistribution-approved game
payload at `${SDL_GetBasePath()}/Aleona`, then launch the SDL3 Stratagus
artifact. Engine startup emits exactly `PEONPAD_ENGINE_READY` only after
`PreMenuSetup()` succeeds. It is a raw stdout line that is flushed before
startup continues; output failure is fatal. Missing scripts/assets and renderer,
surface, I/O, or audio initialization failures terminate nonzero without that
marker; automation must not retain readiness from an earlier process.

Clean all-target Release builds on July 19, 2026 produced arm64 engine and shell
executables for xrsimulator platform 12 and unsigned xros platform 11. This is
compile/link and bundle-structure evidence only. The current shell continues
to launch the public foundation payload and display
`SMOKE SHELL — NO GAMEPLAY`.

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
The staged engine derives a single SDL renderer scale and logical-coordinate
viewport from this geometry, disables SDL logical presentation to avoid double
scaling, and converts SDL3 pointer/touch events through the active renderer
before dispatch.
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

On July 18, 2026, the automated xrsimulator lane passed on Xcode 26.6, CMake
4.3.1, and the visionOS 26.5 Simulator SDK. Fresh install, launch, three
residency checks, explicit termination, different-PID relaunch, three more
residency checks, readiness markers, and first-party log scans all passed on
Apple Vision Pro / visionOS 26.5. The retained fresh screenshot was manually
inspected: it showed the expected native SDL3 + Metal card, exact 4:3 aspect-fit
surface, and “SMOKE SHELL — NO GAMEPLAY.” This is current-shell evidence only,
not a generic pixel or wording assertion. The screenshot, logs, generated app,
and JSON report remain local and are not committed.

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

The automated `xros` lane passed on July 18, 2026 against SDK 26.5 and confirmed
that the command-line bundle is unsigned. Physical acceptance therefore still
requires all of the following local-only steps: select a unique bundle
identifier, enable Xcode automatic signing, provide `DEVELOPMENT_TEAM` through
the local Xcode account, allow Xcode to create/embed a development provisioning
profile, pair and trust an Apple Vision Pro, opt in with
`PEONPAD_VISIONOS_DEVICE_INSTALL=1`, install that signed platform-11 bundle, and
manually verify launch, rendering, input, audio, suspend/resume, and termination
on the device. No signing identity, profile, credential, or device install is
handled by automated acceptance.

## Bundle and content checks

Bundle verification covers arm64 architecture, platform/minimum OS, scene
metadata, app icon catalog, public image/audio fixtures, system-framework
linkage, safe rpaths, and proprietary-content scans. The app has no bundled or
ignored Warcraft content and writes no source-adjacent state; SDL's pref path is
inside its application container.

RealityKit, SwiftUI ornaments, immersive spaces, ARKit or custom hand skeletons,
true 3D rendering, controller-remapping UX, engine packaging, and playable
gameplay are explicitly out of scope for this shell.
