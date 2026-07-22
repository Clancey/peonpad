# Native visionOS tabletop foundation and gameplay slice

PeonPad has a second, entirely separate native visionOS target: a SwiftUI +
RealityKit **tabletop** app that renders a placeable, spatially-manipulable
procedural battlefield board with upright transparent unit billboards. It
includes a production-quality gameplay slice with a versioned, Codable pure-
state snapshot model, deterministic command reduction, and interactive unit
selection and movement. There is no Stratagus, no proprietary Warcraft II art
or data -- only representative procedural content to prove the spatial board,
gesture, and gameplay mechanics.

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
  board from the gameplay snapshot, wires `SpatialEventGesture` input, and
  re-orients every unit's billboard once per frame.
- A pure, RealityKit-independent Swift module (`TabletopGestureState.swift`)
  that holds every piece of deterministic gesture logic: gesture-sample
  interpretation, chirality-based command/board-manipulation routing, two-hand
  scale, and the camera-relative directional-billboard frame resolution. This
  file imports nothing from RealityKit/SwiftUI/UIKit and is unit tested on the
  host Mac (see below), independent of any simulator or device.
- A pure, RealityKit-independent gameplay module (`TabletopGameplayState.swift`)
  that holds the versioned Codable snapshot model and command reducer (see
  below). Also imports nothing from RealityKit/SwiftUI/UIKit.

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

## Gameplay slice: snapshot model and command reducer

`TabletopGameplayState.swift` is a pure-logic module (no UIKit/RealityKit/
SwiftUI) that holds the complete gameplay state for the interactive tabletop
slice:

- **`TabletopGameplaySnapshot`** -- a versioned (`version: Int`), `Codable`,
  value-type record containing the full battlefield: `mapSize`, per-tile
  `terrain` (`[TabletopTerrainTile]`), per-tile `fogMask` (`[TabletopFogTile]`),
  `units` (`[TabletopGameplayUnit]`), and `selection`
  (`TabletopGameplaySelection`). The `validatedSelectedUnit` computed property
  returns the currently selected unit only if it is alive (`hp > 0`),
  preventing dead-unit visual state from persisting after a unit is killed.

- **`TabletopGameplayUnit`** -- one unit's complete state: stable `id`,
  `owner` (player/team index), `hp`, `maxHP`, `facingRadians`, `tileX`, and
  `tileZ`. `isAlive` is `hp > 0`.

- **`TabletopGameplayCommand`** -- a `Codable` enum covering the four
  operations the right-hand command reducer can dispatch: `selectUnit(id:)`,
  `deselectAll`, `moveUnit(id:toTileX:toTileZ:)`, and `stopUnit(id:)`.

- **`TabletopGameplayCommandReducer`** -- two static pure functions:
  - `validate(_:command:)` returns `.valid`, `.rejectedUnitNotFound(id:)`, or
    `.rejectedDeadUnit(id:hp:)`.
  - `reduce(_:command:)` validates then applies the command, returning the
    new snapshot unchanged when the command is invalid. Dead units (`hp == 0`)
    are rejected by every command; the snapshot never partially mutates on
    failure.

- **`TabletopGameplaySnapshot.demo()`** -- a representative procedural
  battlefield (7 × 7 tiles, mixed terrain, eight alive test units across two
  player teams, all fog revealed) used as the initial state in the app and as
  test fixtures. No proprietary Warcraft II data.

### Two-hand suppression (defect regression)

Staggered two-hand release must never dispatch an accidental right-hand
gameplay command. Whenever both hands are simultaneously active (two-hand
board-manipulation mode), the bridge layer in `TabletopBoardView` calls
`commandReducer.suppressRightHandID(_:)` with the current right-hand event
ID. The `TabletopCommandReducer` (in `TabletopGestureState.swift`) tracks
these IDs in a `Set<Int>` and silently drops any `.ended` or `.cancelled`
event whose ID is in the set, removing the ID afterwards so the same numeric
ID cannot be accidentally suppressed in a later, unrelated gesture. This
prevents the defect where a left-hand board-grab followed by a right-hand
pinch on a unit would fire a selection command when the left hand released
first and the right-hand terminal event subsequently arrived.

### Dead-unit defensive rejection

`TabletopGameplayCommandReducer.validate` rejects any `selectUnit`, `moveUnit`,
or `stopUnit` command whose target unit has `hp == 0`. The `reduce` function
returns the snapshot unchanged on any invalid command. `validatedSelectedUnit`
also defensively returns `nil` when the previously-selected unit has since died,
so rendering code never needs to guard for this case.

## Engine transport layer (PR: tabletop-engine-transport)

This PR (stacked on PR #12, branched from `clancey-clancey-tabletop-engine-bridge`)
adds the production Swift↔C integration layer.

### Architecture

```
SwiftUI / RealityKit board view
        │ TabletopGameplaySnapshot (Swift value)
        │ TabletopGameplayCommand  (Swift enum)
        ▼
TabletopGameplaySource / TabletopCommandSink
  └── LiveTabletopSession
        │
        ▼
TabletopEngineTransport          ← NEW: concrete TabletopTransport
  │  poll peonpad_tabletop_latest_snapshot() @ 20 Hz
  │  post peonpad_tabletop_post_command()
        │
  PeonPadTabletopBridge C ABI   ← PR #12 (linked via module.modulemap)
        │
  Stratagus game loop (PEONPAD_TABLETOP build)
        │ peonpad_tabletop_publish_snapshot() per tick
        │ peonpad_tabletop_drain_commands()  per tick
```

**`TabletopEngineTransport`** (`TabletopEngineTransport.swift`):
- Polls `peonpad_tabletop_latest_snapshot()` at ~20 Hz on a background Task.
  When `generation` advances, converts the C snapshot to a Swift
  `TabletopGameplaySnapshot` and yields it on the `AsyncStream`.
- `PeonPadSnapshot` is an opaque/incomplete C type; Swift imports
  `PeonPadSnapshot *` as `OpaquePointer`. All field access is via the ABI
  accessor functions.
- ABI version validated on every snapshot; mismatches are logged and dropped.
- Terrain count consistency (`terrain_count == map_width × map_height`)
  validated; incoherent snapshots dropped.
- Unit count clamped to `PEONPAD_TABLETOP_MAX_UNITS` with a warning.
- Coordinate mapping: Swift `tileZ` ↔ C `tile_y` (map row).
- Facing: Stratagus byte 0–255 → radians via `byte/256.0 × 2π`.
- Terrain-kind mapping: approximate from common Wargus summer-tileset index
  ranges (0x00–0x0F grass, 0x10–0x2F dirt, 0x30–0x5F water, 0x60–0x7F rock,
  0x80–0x9F forest). Exact tileset-aware mapping owned by the next session.
- All five command types mapped: `selectUnit`, `deselectAll`, `moveUnit`,
  `stopUnit`, and (via `moveUnit` with id) `PEONPAD_CMD_MOVE` with unit_id≠0.
- Non-numeric unit IDs (demo fixtures) logged and dropped gracefully.
- `#if canImport(PeonPadTabletopBridge)` guard: a stub implementation compiles
  when the C bridge is not linked (pure-Swift host test targets).

**`TabletopEngineLifecycle`** (`TabletopEngineLifecycle.swift`):
- State machine: `.initializing` → `.ready` | `.error(_)` → `.shutdown`.
- `start(paths:)` launches a detached background Task that validates the
  game-data path, then calls `peonpad_tabletop_init()`.
- `stop()` cancels the init Task and calls `peonpad_tabletop_cleanup()` if
  the bridge was successfully initialized. Idempotent.
- Exposes an `AsyncStream<TabletopEngineState>` (`stateUpdates`) for lifecycle
  gating: the board view shows a diagnostic overlay until `.ready`.

**`TabletopDataPaths`** (`TabletopDataPaths.swift`):
- `resolve()` throws `gameDataUnavailable` when `Documents/wargus-data/` is
  absent (requires `inject-visionos-wargus-data.sh` from PR #13). **No silent
  demo fallback.** `userDataPath()` creates `Library/Application Support/PeonPad/`
  on first use.

**`platform/bridge/module.modulemap`** — Clang module definition that lets
Swift code `import PeonPadTabletopBridge`. Build uses `-I platform/bridge -Xcc
-I platform/bridge` to find it; link adds `PeonPadTabletopBridge.o` and
`-lc++` for the C++ runtime.

**`TabletopApp.swift`** updated:
- `TabletopAppCore` bundles lifecycle, transport, and session so they share
  one object graph.
- `start()` resolves data paths via `TabletopDataPaths.resolve()` and calls
  `lifecycle.start(paths:)` in a `.task` modifier on the launcher window.
- `stop()` called on immersive-space `.onDisappear` for clean shutdown.
- If data paths are unavailable, the lifecycle remains `.initializing` (never
  `.ready`), so `LiveTabletopSession` produces an empty stream and the board
  shows its no-transport diagnostic overlay without crashing.

### Build

```sh
# Host Mac transport + C bridge tests (no Simulator):
./scripts/test-visionos-tabletop-transport.sh   # 76/76 checks

# visionOS Simulator app bundle (now links C bridge):
./scripts/build-visionos-tabletop.sh xrsimulator

# All host-Mac pure-logic suites:
./scripts/test-visionos-tabletop-gestures.sh   # 99/99
./scripts/test-visionos-tabletop-gameplay.sh   # 171/171
./scripts/test-visionos-tabletop-live-state.sh # 45/45
```

## Build, test, and launch

Pure-logic unit tests run on the host Mac, independent of any SDK or
simulator, and are part of `tests/script-guardrails.sh`:

```sh
./scripts/test-visionos-tabletop-gestures.sh   # gesture, billboard, two-hand suppression
./scripts/test-visionos-tabletop-gameplay.sh   # snapshot model, command reducer, dead-unit rejection
./scripts/test-visionos-tabletop-live-state.sh # live-state seam: source/sink/reconciler
./scripts/test-visionos-tabletop-transport.sh  # Swift↔C transport, lifecycle, data paths
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
Vision Pro simulator. The retained screenshot shows the terrain-coloured board
tiles, eight translucent colored cylindrical unit billboards clearly rising off
their tiles, and the board-attached "Tabletop / Recenter" palette near the
board's front edge -- all inside the immersive space, none of it a flat
window. `tests/script-guardrails.sh` (including the tabletop-specific static
checks, the 99/99-passing gesture pure-logic test run, and the 171/171-passing
gameplay pure-logic test run) passed in full.

## Scope boundary

RealityKit/SwiftUI ownership in this app is confined entirely to
`platform/apple/visionos/tabletop`; nothing under the smoke shell's
`platform/apple/visionos` files was touched. There is no Stratagus, no map
loading, no real unit stats or sprite art, and no persistent save state --
only a procedural demo board, a roster of eight tinted placeholder units (one
per canonical direction, two player teams), and the gesture/board-manipulation/
directional-billboard/gameplay mechanics described above.
