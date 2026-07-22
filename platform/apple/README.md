# Apple platform layer

Shared macOS and iPadOS platform integration belongs here. Platform-specific
filesystem, lifecycle, rendering, and input behavior must sit behind explicit
Apple target boundaries rather than being patched into reference material.

The native visionOS 2.0+ SDL3 smoke shell lives under `visionos/`. Its scene
manifest delegates app/window ownership to SDL3's supported UIKit scene
delegate, while the Objective-C++ slice verifies the public UIKit/Metal window
properties and requests freeform resizing. It is a non-game smoke shell; the
guarded full SDL3 Stratagus engine remains disabled.

The separate native visionOS tabletop app lives under `visionos/tabletop/`.
Its SwiftUI entry point owns a mixed immersive space containing a procedural
RealityKit board, upright unit billboards, public chirality-aware direct-pinch
handling, and a board-attached status/recenter palette. It shares neither an
entry point nor a scene delegate with the SDL3 shell.

The iPad application Info.plist template lives in `ios/Info.plist.in`. Build
the unsigned physical-device bundle with `scripts/build-ios-app.sh`; the
generated bundle remains under `build/` and is never a reference input.

`ios/PeonPadLaunch.svg` is the game-independent source for the PeonPad launch
screen and references the canonical icon in `PeonPadAssets.xcassets`. The
checked-in opaque launch PNG and required iPad icon renditions are declared by
`Info.plist.in` and copied into both the command-line and Xcode bundles. The
build verifies those resources byte-for-byte; no Aleona, Wargus, Warcraft, or
Blizzard artwork is used for application branding.

Xcode post-build commands cannot safely use CMake's generated bundle path here:
Xcode leaves `${EFFECTIVE_PLATFORM_NAME}` escaped in that command. The small
`copy-xcode-bundle-resources.sh` bridge instead uses Xcode's authoritative
`TARGET_BUILD_DIR` and `WRAPPER_NAME` environment values. A guardrail fixture
exercises that exact resource-copy route without requiring signing or a device.

The iOS viewport layer is split deliberately:

- `PeonPadViewportGeometry.*` calculates one exact-aspect viewport inside pixel
  safe-area insets, provides inverse bar-aware input mapping, and is testable on
  macOS under `-DNDEBUG`.
- `PeonPadIOSViewport.mm` obtains UIKit safe-area insets from SDL's `UIWindow`,
  converts them from points to Retina drawable pixels, and applies one SDL
  viewport/scale transform for both rendering and SDL event conversion.

The engine selects SDL's Metal renderer on iOS and reapplies this viewport
after UIKit size changes. The Home gesture requires a deliberate second swipe,
while game controls remain inside the safe region.
