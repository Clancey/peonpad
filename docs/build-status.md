# PeonPad build status

Status updated: 2026-07-19

Remote-to-local handoff updated: 2026-07-11

Physical-device testing is now active. PeonPad has been signed with the local
Personal Team, installed over USB, launched, and used to start King of the
Hill, For the Motherland, and Skirmish Classic matches. The gameplay-only
three-finger camera pan is now working in device testing. Current findings,
content decisions, and the control design are recorded in
[ipad-test-notes.md](ipad-test-notes.md).

The public device profile now accepts an ignored root-level or external
`data.Wargus`, staged without its redundant installer MPQ. The engine
remains a native ARM64 iPadOS/Metal build; no Windows executable is run or
emulated. Proprietary data remains ignored and is not part of the repository.

The public preparation path no longer requires the private `ref/` fixture.
`scripts/prepare-ipad-build.sh` accepts either the exact validated English GOG
Battle.net Edition 2.02 installer pair or an existing `data.Wargus`, builds the
host tools, stages the payload, and generates the native Xcode project. The
already-extracted route has completed locally from a clean host build tree. A
true unrelated clean clone and the raw-installer branch remain acceptance work.

The first delayed-touch recognizer was rejected during physical testing after
it swallowed taps in gameplay and in-game menus. The installed recovery build
restores SDL single-touch behavior while retaining gameplay-only multi-touch
commands and explicit selection-rectangle cancellation.

Device console capture identified the apparent Front Lines freeze as a content
termination: the legacy map references the undefined `unit-nomad` type and the
engine exits with code 1. Random Skirmish also reports an extended/base tileset
brush mismatch. The private Warcraft II device menu now exposes only Skirmish
Classic and Skirmish Modern under Standard Game; original campaigns remain
available separately.

Physical follow-up proved Beyond the Dark Portal Alliance Act I renders and
plays correctly, including touch and camera pan. Skirmish Modern also runs, but
its default map intentionally starts at the map edge with one peasant and can
initially resemble an empty scene. The incompatible custom-mode files are now
physically absent from the staged iPad payload rather than merely filtered by
the menu widget.

The current device control candidate uses one-finger selection with empty-map
deselection, a two-finger chord for right-click commands at the leftmost
finger's position, and three-finger drag for camera panning. Two-finger movement beyond
a small tolerance cancels the command, and adding the third finger cancels the
pending command before panning. The pan now has a 1.35 movement gain, and text
fields reactivate UIKit's software keyboard when tapped. SDL's separate
hardware keyboard, mouse, and trackpad paths remain enabled for Magic Keyboard
and external pointer testing.

The opt-in direct SDL3 lane now builds the complete staged Stratagus engine
against the immutable SDL 3.4.12, SDL_image 3.4.4, and SDL_mixer 3.2.4
archives. The port covers lifecycle/events, renderers, surfaces and palettes,
SDL IO/image ownership, the SDL_mixer 3 object model, controllers, Guisan,
OpenGL/YUV movies, and all SDL-dependent engine/tool call sites through small
typed compatibility boundaries. SDL2 remains the default and accepted
fallback.

Clean July 19 Release evidence includes full arm64 macOS SDL3 and SDL2
Stratagus/Wargus/tool builds, 74 SDL3 tests and four SDL2 compatibility tests,
software and Metal foundation runtime, and complete iOS Simulator,
xrsimulator, and unsigned xros all-target SDL3 engine builds. This is full
engine source and link parity, not packaged native visionOS gameplay. See
[sdl3-foundation.md](sdl3-foundation.md).

The SDL3 foundation now owns a native visionOS 2.0+ smoke-shell application
layer. Separate arm64 xros and xrsimulator configurations produce platform-11
and platform-12 bundles with a UIKit window scene, Metal renderer, freeform
resizing, layered PeonPad icon, and one exact 4:3 geometry/input transform. On
July 15, 2026, the clean Simulator app installed, launched, remained resident,
and rendered its public “SMOKE SHELL — NO GAMEPLAY” card on Apple Vision Pro /
visionOS 26.5. The complete unsigned device build also passed bundle inspection;
the visible physical Vision Pro was unavailable, so Xcode team signing and
hardware install remain external gates. This does not enable or claim gameplay.
See [visionos-shell.md](visionos-shell.md).

The existing iPad target now has a separate Designed-for-iPad Vision Pro
simulator path. Xcode 26.6 advertises the scheme at a `visionOS Simulator`
destination with the `Designed for [iPad,iPhone]` variant, while actually
building an arm64 iOS Simulator platform-7 executable with the iPhoneSimulator
26.5 SDK. On 2026-07-15 that app built, installed, launched, and remained
running under the visionOS 26.5 simulator with a generated non-game probe
payload; no proprietary data was accessed. It is not an xros build, and the
probe is not gameplay acceptance. Eye/hand input, control ergonomics, audio,
lifecycle, sustained performance, and complete gameplay remain Vision Pro
hardware-only acceptance.

Replay Game and Save Replay are hidden in the private iPad profile after device
testing found that both legacy and newly generated logs failed to play
reliably. The engine also retains a missing-map preflight so stale files cannot
reach the fatal map loader if replay UI is re-enabled later.

This is the handoff point for resuming the active PeonPad goal with a physical
M2 iPad Pro. It distinguishes completed engineering from acceptance work that
still requires the device or external licensing evidence.

## Public build handoff

The pushed GitHub source is now the authoritative portable build input. The
ignored `ref/`, `data.Wargus`, `build/`, and `runtime/` trees are local state and
must never be added to the repository.

From a clone, install the prerequisites shown in the root README and choose one
preparation route:

```sh
./scripts/prepare-ipad-build.sh --installer "/path/to/validated/setup.exe"
```

or:

```sh
./scripts/prepare-ipad-build.sh --data "/path/to/data.Wargus"
```

The command runs the public preflight, creates a clean host build, stages an
ignored Warcraft II payload and generates
`build/ios-xcode/stratagus.xcodeproj`. It does not download game data, install
packages, modify the source data, or manage Apple credentials.

Connect and trust the iPad, confirm it appears in
`xcrun devicectl list devices`, then choose the Personal Team and connected
device in Xcode. A unique bundle identifier may still be required for a new
Apple account.

Maintainers can separately run `./scripts/preflight.sh --maintainer` to verify
the original private evidence fixture. That check is intentionally outside the
public installation contract.

## Executive status

Goals 0, 1, and 2 are complete and locally verified. Goal 3 is running on the
physical iPad: launch, menus, audio, and multiple live maps are proven, while a
complete-match regression remains. Goal 4 has started with
gameplay-only multi-touch controls and remains unaccepted until the device
regression matrix passes.

The iPad and local Personal Team signing are no longer blockers. The remaining
content blocker is unchanged: 797 Aleona media files lack a verified
redistribution grant, so the current Aleona payload is local-test-only and must
not be published or distributed.

## Goal evidence

| Goal | State | Current evidence |
| --- | --- | --- |
| Goal 0 — reproducible baseline | Complete | Public preflight passes from tracked source snapshots; optional maintainer mode preserves the private reference gate. |
| Goal 1 — macOS baseline | Complete | A clean host build produces Stratagus, Wargus, `wartool`, `pudconvert`, and the required `toluapp`; runtime state is isolated under `runtime/`. |
| Goal 2 — iOS arm64 libraries | Complete | Stratagus, Wargus data layer, SDL2, SDL2_image, SDL2_mixer, Lua, tolua++, zlib, PNG, Ogg, Vorbis, Theora, and the remaining confirmed dependencies build as iOS arm64 artifacts. Architecture/platform verification passes. |
| Goal 3 — first playable iPad slice | Physical regression in progress | The signed app launches on the M2 iPad; campaigns and skirmishes render and play; manual save, autosave, load, and repeated Quit-to-Menu checks pass. A complete-match regression remains. The Aleona snapshot is not redistribution-cleared. |
| Goal 4 — Apple input | In progress | One-finger selection, leftmost-target two-finger commands, and three-finger camera pan are implemented and undergoing physical regression testing. Discoverable Shift/Control/Alt controls are designed but not implemented. |

## Phase 2 implementation proven locally

The current iOS app includes:

- SDL's UIKit application wrapper and an explicitly selected Metal renderer;
- an aspect-preserving safe-area viewport with UIKit point-to-Retina-pixel
  conversion shared by rendering and SDL input-coordinate conversion;
- landscape-left and landscape-right iPad orientations;
- `UIApplicationSupportsIndirectInputEvents = YES`;
- application-container writable state through `SDL_GetPrefPath`;
- bundled-data discovery through `SDL_GetBasePath()/Aleona`;
- original PeonPad launch artwork and opaque iPad icon renditions containing no
  game-derived branding;
- an application-bundle scan that rejects MPQs, installers, `data.Wargus`, and
  other proprietary Warcraft II inputs.

The Xcode route received an additional fix during the final audit. CMake 3.27
escaped Xcode's `${EFFECTIVE_PLATFORM_NAME}` in a post-build bundle path,
placing Aleona and artwork in a literal, incorrect directory. The
`platform/apple/ios/copy-xcode-bundle-resources.sh` bridge now uses Xcode's
authoritative `TARGET_BUILD_DIR` and `WRAPPER_NAME`. A clean unsigned Xcode
Release build and an incremental build both succeeded, and the real
`Release-iphoneos/PeonPad.app` now contains Aleona plus every declared launch
and icon resource.

Local application artifacts, intentionally excluded from Git, are:

```text
build/ios-arm64/engine/PeonPad.app
build/ios-xcode/Release-iphoneos/PeonPad.app
build/ios-xcode/stratagus.xcodeproj
```

Both executables are arm64 Mach-O files with `LC_BUILD_VERSION` platform iOS,
minimum iOS 16.0, and SDK 26.5. Both are intentionally unsigned. The native
Xcode project is generated reproducibly with `scripts/generate-ios-xcode.sh`.

## Immutable inputs and publication boundary

The locked reference digest is:

```text
c1782ea011559049ce65b739c6cbe5825a4db3b1c8d2afaea0dbcb54e7357f8f
```

Locked source revisions are recorded in `config/inputs.lock`, including:

- Stratagus: `3d87c93f7fd8c0b62ee1be5df0a6d9efc72ca6cc`
- Wargus: `cde1a0718a0058cc651ecd56ff8149fc39f624e9`
- Stratagus Vita: `5454452ec3ef9f6a14e51a57be8fe13e44893cdf`
- Aleona's Tales: `695d3ed6464cfa186c42e4804ee1e2c4e88f6e09`

The following remain local and must never be committed or pushed:

- `ref/`, including applications, installers, logs, repositories, and extracted
  Warcraft II data;
- all `data.Wargus` directories, MPQs, and installers;
- `build/`, `runtime/`, saves, caches, logs, signing identities, profiles, and
  local configuration;
- `assets/aleonas-tales/source/` while its asset audit remains unresolved.

The Aleona audit inspected 2,849 media files: 2,037 are covered by the vendored
Wyrmsun declaration, 15 non-vendor files have explicit grants, 112 have author
attribution without a license grant, and 685 lack adjacent provenance. The
unresolved total is 797. `PEONPAD_DISTRIBUTION_BUILD=1` makes both iOS build
entry points run the strict audit and stop before compilation. See
`aleona-asset-audit.md` for evidence and remediation paths.

## Resume checklist for the physical iPad

1. Connect the unlocked M2 iPad Pro to the Mac by USB.
2. Accept **Trust This Computer** on the iPad and enter its passcode.
3. If iPadOS requests it, enable **Settings → Privacy & Security → Developer
   Mode**, restart, and confirm Developer Mode after restart.
4. Confirm the device is visible:

   ```sh
   xcrun devicectl list devices
   ```

5. In **Xcode → Settings → Accounts**, add the Apple ID natively and allow
   Xcode to create a Personal Team development certificate. No third-party
   credential tool is used.
6. From the PeonPad root, prepare the native project from owned data:

   ```sh
   ./scripts/prepare-ipad-build.sh --data "/path/to/data.Wargus"
   open build/ios-xcode/stratagus.xcodeproj
   ```

7. Select the `stratagus` target, choose the Personal Team under **Signing &
   Capabilities**, select the connected iPad as the run destination, and press
   **Run**.
8. Verify the PeonPad launch mark appears, the app remains landscape, the menu
   stays inside safe areas at Retina resolution, and no import prompt appears.
9. Start a Warcraft II skirmish, verify Metal rendering and OGG audio, play through
   a complete match, then relaunch and confirm preferences/saves remain inside
   the application container.
10. Capture Xcode device-console output and any visual defects outside the
    repository's proprietary-data and build directories.

Passing all ten steps completes the remaining full-match regression. It does
not grant redistribution rights for the user's Warcraft II data.

## Revalidation commands

Public source and toolchain checks:

```sh
./scripts/preflight.sh
./tests/script-guardrails.sh
./scripts/test-ios-viewport.sh
./scripts/preflight-vision-compat.sh
./scripts/build-macos.sh
PEONPAD_WC2_DATA_DIR="/path/to/data.Wargus" ./scripts/smoke-macos.sh
```

Optional private maintainer evidence checks:

```sh
./scripts/preflight.sh --maintainer
./tests/script-guardrails.sh --maintainer
./scripts/reference-digest.sh
```

Expected nonfatal warnings are recorded in `ios-static-libraries.md` and
`ios-app-shell.md`. They are primarily upstream deprecation and precision
warnings plus duplicate static-library link warnings. No new PeonPad platform
bridge warning remains.
