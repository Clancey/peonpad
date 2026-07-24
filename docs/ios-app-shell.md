# Phase 2 iPad app shell

The first PeonPad physical-device application now builds as an unsigned arm64
iOS bundle:

```sh
./scripts/build-ios-app.sh
```

Output:

```text
build/ios-arm64/engine/PeonPad.app
```

The build is native iOS (`LC_BUILD_VERSION` platform 2), targets iPadOS 16.0,
and links the vendored SDL2 engine as a Metal-capable SDL application. The
bundle is landscape-only, enables indirect pointer input, writes preferences
and saves through `SDL_GetPrefPath`, and locates its bundled game scripts from
`SDL_GetBasePath()/Aleona`.

The system launch screen displays the original PeonPad tablet-and-banner mark,
and the bundle includes matching opaque 76-point, Retina 76-point, and
83.5-point Retina iPad icons. Their vector source is kept beside the generated
PNGs under `platform/apple/ios`; none is derived from game content.

The iOS engine now explicitly selects SDL's `metal` renderer. UIKit safe-area
insets are converted from points into Retina drawable pixels, and the 4:3 game
surface is aspect-fitted inside that safe rectangle. The same SDL viewport and
scale drive SDL's built-in pointer/touch event conversion, avoiding a second
coordinate transform. Insets are reapplied after UIKit size changes, and the
Home gesture uses SDL's two-swipe deferral mode.

The platform-independent viewport calculation is covered by:

```sh
./scripts/test-ios-viewport.sh
```

## Content boundary

The script fails if an MPQ, installer, `WAR2DAT.MPQ`, or `data.Wargus`
directory appears in the application. It also verifies the locked `ref/`
digest before and after every build.

The current Aleona snapshot is approved only for local development testing.
Its aggregate repository is GPLv2, but the per-file art, audio, map, and
vendored Wyrmsun provenance audit remains
`REVIEW_REQUIRED_BEFORE_BUNDLING`. Do not distribute this application bundle
until that audit is complete. The reproducible findings and remediation paths
are recorded in [aleona-asset-audit.md](aleona-asset-audit.md). Setting
`PEONPAD_DISTRIBUTION_BUILD=1` makes both iOS entry points run the strict audit
and refuse the current snapshot.

## Proven locally

- `PeonPad.app/PeonPad` is a Mach-O arm64 executable.
- Its load command records iOS platform 2, minimum 16.0, SDK 26.5.
- The generated Info.plist identifies an iPad application and enables
  `UIApplicationSupportsIndirectInputEvents`.
- The Info.plist declares a nonblank PeonPad launch image and matching iPad
icons, and the build verifies that every declared raster is in the bundle.
- Xcode resource copying uses `TARGET_BUILD_DIR` and `WRAPPER_NAME`, avoiding
  CMake's incorrectly escaped `${EFFECTIVE_PLATFORM_NAME}` post-build path.
- Aleona scripts and media are present; no Blizzard-derived data is present.
- The final executable links successfully with SDL2, SDL2_image, SDL2_mixer,
  Lua, and the vendored media libraries.
- Both the Makefile device build and a clean native Xcode Release build contain
  the UIKit safe-area bridge and produce arm64 iOS 16.0 applications.
- SDL_mixer uses Timidity for MIDI on iOS. Its macOS native-MIDI backend is
  deliberately disabled because that implementation compiles empty under the
  iPhoneOS SDK and otherwise leaves unresolved symbols.

## Remaining Phase 2 acceptance

After staging owned Warcraft II data, generate the native Xcode project used
for automatic personal-team signing with:

```sh
./scripts/generate-ios-xcode.sh
open build/ios-xcode/stratagus.xcodeproj
```

In Xcode, select the `stratagus` target, open **Signing & Capabilities**, and
choose your Personal Team. Select the connected iPad as the run destination
and press Run. This uses only Xcode and the Apple account stored by Xcode; no
third-party credential tool is involved.

The generator defaults to ignored `build/ios-wc2-data` and removes its
script-owned build tree first so stale
ExternalProject caches cannot retain an incompatible CMake generator. The
generated project has been proven through a complete unsigned Xcode Release
build. Its top-level PeonPad target is native Xcode while vendored
dependencies use their verified single-configuration CMake builds. A
connected, paired iPad and a signing team configured natively in Xcode are
still required to install it. Physical M2 iPad testing has since accepted
launch, menus, Warcraft II campaigns and skirmishes, Metal rendering, audio,
save/load, and the current touch controls; see `ipad-test-notes.md` for the
remaining regression matrix.

## Designed-for-iPad Vision Pro compatibility

Xcode 26.6 exposes the existing iPad-only `stratagus` scheme on an Apple Vision
Pro simulator as:

```text
platform=visionOS Simulator, variant=Designed for [iPad,iPhone]
```

The destination still builds PeonPad with `PLATFORM_NAME=iphonesimulator`,
`EFFECTIVE_PLATFORM_NAME=-iphonesimulator`, and the iPhoneSimulator 26.5 SDK.
The resulting arm64 executable records `LC_BUILD_VERSION` platform 7 (iOS
Simulator), minimum iOS 16.0. It is not built with xros or xrsimulator.

The physical-device generator cannot be reused unchanged for this destination:
its vendored dependencies are intentionally fixed to `iphoneos`, which produces
a device-versus-simulator linker error. The separate compatibility path keeps
those dependencies on `iphonesimulator` while explicitly allowing Xcode to
advertise the Designed-for-iPad destination:

```sh
./scripts/preflight-vision-compat.sh
./scripts/build-vision-compat-simulator.sh --launch
```

The compatibility build uses an isolated PeonPad-owned Vision Pro destination
by default and deletes only that device on exit. Reusing a user simulator
requires an explicit UDID and `--allow-user-simulator`; automation does not
foreground it. See
[`visionos-simulator-automation.md`](visionos-simulator-automation.md).

On 2026-07-15, the compatibility app built, installed, and remained running on
the visionOS 26.5 Apple Vision Pro simulator with a generated non-game probe
payload; no proprietary data was accessed. This proves only build and
compatibility-runtime startup, not gameplay. Vision Pro hardware is still
required to accept eye/hand targeting, indirect pointer and keyboard behavior,
gesture discoverability, audio, lifecycle, comfort, sustained performance, and
complete gameplay.
