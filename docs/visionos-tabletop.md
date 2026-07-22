# Native visionOS tabletop foundation

`peonpad_tabletop` is a separate native visionOS 2.0+ application target. It
does not replace the Designed-for-iPad gameplay route or the SDL3 smoke shell,
and it does not compile or bundle Stratagus, Wargus, or proprietary game data.

## Spatial scene

The SwiftUI `WindowGroup` uses `.windowStyle(.volumetric)` with a default
1.25 × 0.55 × 0.95 meter volume. RealityKit creates a physical board, raised
terrain tiles, river, bridge, keeps, trees, and command marker entirely from
primitives. The system volume can be placed like any visionOS volume; the board
is not rendered into a conventional UIKit rectangle.

A SwiftUI status/recenter palette is supplied as a `RealityView` attachment and
parented to the board root near its player-facing edge. Translation and scaling
therefore move the palette with the board. There is no persistent head-locked
primary UI.

## Spatial input boundary

The app consumes public `SpatialEventGesture` events and accepts only
`SpatialEventCollection.Event.kind == .directPinch`. On visionOS 2 or newer,
`Event.chirality` maps input deterministically:

| Input | Foundation intent |
| --- | --- |
| Right-hand pinch begins | Emit one command/select intent and place the marker |
| Left-hand pinch moves | Translate the board pose |
| Both pinches active | Scale the board from the initial hand separation |
| Recenter button | Reset pose and clear active gesture state |

`TabletopGestureState.swift` contains no SwiftUI, RealityKit, or ARKit types.
The host Swift test checks edge triggering, translation, scale baselines and
clamps, cancellation, one-hand release continuity, and recentering. Layer 1
does not use ARKit hand skeletons, private APIs, continuous eye gaze, or route
intents into gameplay.

## Build and launch

Build the simulator app, optionally launching it and retaining screenshot
evidence outside the checkout:

```sh
./scripts/build-visionos-tabletop.sh xrsimulator
./scripts/build-visionos-tabletop.sh xrsimulator --launch \
  --screenshot /tmp/peonpad-tabletop.png
```

The script runs the reducer test, generates a fresh Xcode project, builds only
the separate tabletop target, compiles the legal PeonPad icon catalog, ad-hoc
signs the simulator bundle, verifies SwiftUI/RealityKit linkage and volumetric
metadata, installs it, and requires the launched PID to remain resident before
capturing evidence.

An unsigned physical-device compile gate remains available without credentials:

```sh
./scripts/build-visionos-tabletop.sh xros --unsigned
```

For a development-signed device build, provide a local Xcode team and a unique
bundle identifier. Xcode owns account access and provisioning:

```sh
./scripts/build-visionos-tabletop.sh xros \
  --team YOUR_TEAM_ID \
  --bundle-id your.unique.tabletop.bundle
```

The signed route uses `-allowProvisioningUpdates`, requires an embedded profile,
and verifies the resulting signature. Installation uses the existing explicit
device gate:

```sh
PEONPAD_VISIONOS_DEVICE_INSTALL=1 \
  ./scripts/install-visionos-device.sh \
  build/visionos-tabletop-xros/Release-xros/PeonPadTabletop.app \
  DEVICE_IDENTIFIER
```

No team identifier, profile, credential, or generated app is tracked.
