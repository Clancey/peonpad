# Native visionOS tabletop foundation

PeonPad has a second, entirely separate native visionOS target: a SwiftUI +
RealityKit **tabletop** app that renders a placeable, spatially-manipulable
procedural battlefield board with upright transparent unit billboards. This is
a *foundation layer only* -- there is no Stratagus, no map, no proprietary
Warcraft II art or data, and no gameplay. It exists to prove the spatial board,
gesture, and directional-billboard mechanics before any real battlefield data
is ported.

It is fully independent of, and does not modify, either of the branch's other
two native paths:

- The Designed-for-iPad Warcraft II app (UIKit/AppKit + the guarded SDL3
  gameplay engine).
- The native visionOS SDL3 smoke shell (`docs/visionos-shell.md`) -- a single
  `UIApplicationSceneManifest` window scene owned by
  `SDLUIKitSceneDelegate`, with `UIApplicationSupportsMultipleScenes = false`.

The tabletop app has its own bundle identifier (`org.peonpad.visionos.tabletop`,
distinct from the shell's `org.peonpad.visionos`), its own executable
(`PeonPadTabletop`, distinct from the shell's `PeonPadVisionShell`), and is
compiled by a completely separate script and toolchain path. Because a
SwiftUI `@main App` and SDL3's own UIKit app/scene delegate startup cannot
coexist in one executable, this is a second, independent app target rather
than a change to the smoke shell's entry point.

## Why SwiftUI + RealityKit, compiled directly with `swiftc`

The smoke shell is deliberately CMake + SDL3 + UIKit, with no SwiftUI,
RealityKit, or ARKit. Placing a spatial board, right/left-hand chirality
gestures, and camera-relative billboard framing on top of that stack would
mean either reimplementing RealityKit-equivalent 3D scene management by hand
or bringing Swift/RealityKit into the SDL3 shell's process -- both violate
"do not modify or weaken the existing paths." Instead, the tabletop app is:

- A plain SwiftUI `App` (`TabletopApp.swift`) with a `WindowGroup` launcher and
  an `ImmersiveSpace` (`.mixed` style) that the launcher opens automatically.
- A `RealityView`-based scene (`TabletopBoardView.swift`) that builds the
  board, wires `SpatialEventGesture` input, and re-orients every unit's
  billboard once per frame.
- A pure, RealityKit-independent Swift module (`TabletopGestureState.swift`)
  that holds every piece of deterministic logic: gesture-sample interpretation,
  chirality-based command/board-manipulation routing, two-hand scale, and the
  camera-relative directional-billboard frame resolution. This file imports
  nothing from RealityKit/SwiftUI/UIKit and is unit tested on the host Mac
  (see below), independent of any simulator or device.

There is no Xcode project and no CMake target: `scripts/build-visionos-tabletop.sh`
invokes `swiftc -target arm64-apple-xros2.0-simulator` (or the non-simulator
`xros` triple) directly against the installed XRSimulator/XROS 26.5 SDK,
assembles the `.app` bundle by hand (`Info.plist`, compiled asset catalog via
the existing `compile-bundle-assets.sh`, ad-hoc simulator codesigning), and
hands the result to `scripts/verify-tabletop-bundle.sh` for static
verification. This mirrors the spirit of the SDL3 shell's build/verify split
without sharing any of its CMake machinery.

## Product design and gesture model

- **Right hand is the default selection/command hand.** A `.directPinch` with
  `chirality == .right` on a unit selects it (or issues a move/command intent
  once selected); this is handled by `TabletopCommandReducer` in the pure
  logic module.
- **Left hand grabs, rotates, and repositions the board.** A `.directPinch`
  with `chirality == .left` (with no `targetedEntity`, i.e. not on a unit)
  starts a board-manipulation drag; `TabletopBoardManipulator` turns the
  ongoing `SpatialEventCollection.Event` samples (`location3D`,
  `inputDevicePose`) into an incremental translation/yaw for the whole board.
- **Two-hand scaling** activates once both a left- and right-hand
  `.directPinch` are active simultaneously (tracked by chirality, not by
  arbitrary event order); the ratio of the current inter-hand distance to the
  distance at pinch-start scales the board uniformly, clamped to a sane range.
- **Terrain/fog stay glued to the board plane** -- the checkerboard tiles and
  the fog-of-war overlay are children of the same `boardRoot` entity as the
  units, so any board manipulation (move/rotate/scale) carries them together.
- **Units are upright transparent cylindrical billboards** anchored at their
  tile's feet (the unit's root sits at floor level; the cylinder body extends
  upward from there), so they visibly rise off the board rather than lying
  flat on it.
- **Billboard facing is camera-relative but world-orientation-preserving.**
  Every frame, each unit resolves `(unitFacing - viewerAzimuthAroundBoard)`,
  quantizes the result to the eight canonical Warcraft II sprite directions,
  and mirrors the source direction horizontally when the canonical convention
  calls for a mirrored frame (e.g. west reusing a horizontally-flipped east
  frame). The quad only ever yaws around the board's vertical normal to face
  the viewer -- it never pitches or rolls, so it stays upright from any
  viewing angle around the board. `TabletopDirectionalFrame.resolve` and
  `TabletopBillboardOrientation.yawFacingViewer` are the two pure functions
  responsible for this; both are unit tested with the full set of
  facing/viewer-angle combinations, including the mirrored cases.
- **Native controls live in a board-attached palette**, rendered as a
  `RealityView` `.attachment` (`TabletopPaletteView`, a small SwiftUI view with
  a "Recenter" button) parented to `boardRoot` near the player-facing edge of
  the board. There is no persistent head-locked HUD or ornament -- the palette
  moves, rotates, and scales with the board itself.

## Why `UnlitMaterial(color:)` needs explicit blending for translucent parts

`UnlitMaterial(color: UIColor)` does **not** automatically turn a `UIColor`
with `alpha < 1` into a translucent material -- without an explicit
`material.blending = .transparent(opacity:)`, the alpha is silently dropped
and the surface renders fully opaque. This is easy to miss because nothing
errors or warns; the fog-of-war plane and the "transparent" cylindrical unit
bodies simply rendered as solid, whiting out the checkerboard tiles
underneath. `TabletopSceneBuilder.swift` centralizes the fix in one helper,
`translucentUnlitMaterial(_:)`, which reads the color's real alpha via
`UIColor.cgColor.alpha` and sets `.blending = .transparent(opacity:)` whenever
it is less than 1; every material construction in the file goes through it.

## Automated evidence and the Simulator's fixed neutral head pose

`xcrun simctl io <udid> screenshot` captures the Simulator's fixed, neutral
persona head pose -- it cannot be told to tilt down, and there is no
public API to reposition it for an automated screenshot. A board placed at a
literal floor/waist height (as a real tabletop naturally would be) falls
entirely outside that neutral pose's vertical field of view in this
environment, even though a real Vision Pro wearer would simply look down at
it. This was confirmed empirically with a temporary debug sphere at several
heights before any board content was added. The default spawn height and
"Recenter" placement were tuned (`TabletopPlacement` in
`TabletopBoardView.swift`) so the board, its units, and its palette all sit
comfortably inside that fixed neutral frame for repeatable screenshot
evidence, while still reading clearly as an in-space object in front of the
viewer rather than a flat window. This is purely an automated-evidence
concern; nothing about the gesture or manipulation logic depends on this
default height, and a user can move the board anywhere with the left hand.

## Build, test, and launch

Pure-logic unit tests run on the host Mac, independent of any SDK or
simulator, and are part of `tests/script-guardrails.sh`:

```sh
./scripts/test-visionos-tabletop-gestures.sh
```

Build the app bundle (no launch):

```sh
./scripts/build-visionos-tabletop.sh xrsimulator
./scripts/build-visionos-tabletop.sh xros   # unsigned command-line device build
```

Build, install, launch in the Vision Pro Simulator, and capture a screenshot
(evidence must stay outside the repository):

```sh
./scripts/build-visionos-tabletop.sh xrsimulator --launch \
  --screenshot /tmp/peonpad-tabletop-evidence/tabletop.png
```

`--launch`/`--screenshot` are rejected for the `xros` target, matching the
SDL3 shell's simulator-only evidence convention. The `xros` build prints an
explicit "DEVICE GATE" reminder: the command-line binary is intentionally
unsigned, and a physical Vision Pro install requires local Xcode signing
followed by the existing `scripts/install-visionos-device.sh` gate (which is
bundle-agnostic and works unchanged for this app's bundle once signed).

`scripts/verify-tabletop-bundle.sh` performs static bundle checks: distinct
bundle id and executable name (and an explicit rejection if either ever
collides with the SDL3 smoke shell's), arm64/platform/minimum-OS metadata,
`UIApplicationSupportsMultipleScenes = true` (required for a SwiftUI app that
opens an `ImmersiveSpace` alongside a `WindowGroup` -- the opposite of the
smoke shell's single-scene requirement), a hand-tracking usage description,
compiled asset catalog presence, and an absence of any SDL scene delegate or
proprietary Warcraft content.

On July 22, 2026, a full `xrsimulator` build, install, launch, and screenshot
passed against Xcode 26.6 and the visionOS 26.5 Simulator SDK on an Apple
Vision Pro simulator. The retained screenshot shows the checkerboard board,
eight translucent colored cylindrical unit billboards clearly rising off
their tiles, and the board-attached "Tabletop / Recenter" palette near the
board's front edge -- all inside the immersive space, none of it a flat
window. `tests/script-guardrails.sh` (including the tabletop-specific static
checks and the 69/69-passing pure-logic test run) passed in full.

## Scope boundary

RealityKit/SwiftUI ownership in this app is confined entirely to
`platform/apple/visionos/tabletop`; nothing under the smoke shell's
`platform/apple/visionos` files was touched. There is no Stratagus, no map
loading, no real unit stats or sprite art, and no persistent save state --
only a procedural test board, a fixed roster of eight tinted placeholder
units (one per canonical direction), and the gesture/board-manipulation/
directional-billboard mechanics described above.
