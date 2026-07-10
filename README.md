# PeonPad

The current implementation and physical-iPad resume checklist are recorded in
[`docs/build-status.md`](docs/build-status.md).

PeonPad is a de-branded Apple-platform port of the GPLv2 Stratagus/Wargus
real-time strategy engine. Development starts with a reproducible Apple
silicon macOS build and advances to iPadOS only after both desktop content
paths pass their acceptance tests.

PeonPad does not contain, build, or distribute Warcraft II data. Licensed
game data remains a user-provided runtime input. The `ref/` directory is
local-only, immutable reference material and is never part of the project.

## Current phase

Goal 0 is complete: repository boundaries, exact source/dependency revisions,
Xcode, and native/iOS compiler probes are locked. Verify them with:

```sh
./scripts/preflight.sh
```

The command fails on any reference, source, or toolchain drift.

The Goal 1 macOS source build is operational:

```sh
./scripts/build-macos.sh
./scripts/smoke-macos.sh
./scripts/run-macos.sh --profile aleona -- -W
./scripts/run-macos.sh --profile wc2 -- -W
```

The build produces an arm64 Stratagus engine plus the Wargus launcher and
tools. Both content paths pass automated boot smoke checks and interactive
match/save/load acceptance. Random Skirmish writes generated maps only into
the isolated runtime profile, and extracted Ogg/FLAC music now decodes through
the vendored SDL_mixer build. Audible CoreAudio output still needs one physical
Mac session because the remote session has no live audio device.

The Phase 1 iOS static-library gate is also operational:

```sh
./scripts/build-ios-libs.sh
```

It produces physical-device arm64 `libstratagus_lib.a` and
`libwargus_data.a` archives containing only iOS Mach-O objects.

The unsigned Phase 2 iPad application shell also builds:

```sh
./scripts/build-ios-app.sh
```

This produces `build/ios-arm64/engine/PeonPad.app`, a native arm64 iOS bundle
with an explicitly selected SDL Metal renderer, a Retina-aware safe-area
viewport, original PeonPad launch/icon artwork, the local-test Aleona snapshot,
and no Blizzard data. Physical-device
launch acceptance still requires a connected iPad and an Xcode signing team.
The Aleona per-asset licensing audit must pass before distributing that bundle;
see `docs/aleona-asset-audit.md`. Set `PEONPAD_DISTRIBUTION_BUILD=1` to make
the build enforce the strict distribution audit; it correctly fails for the
current local-test snapshot.

For the native Xcode signing and device-deploy route:

```sh
./scripts/generate-ios-xcode.sh
open build/ios-xcode/stratagus.xcodeproj
```

Choose your Personal Team on the `stratagus` target in Xcode. This path uses
Apple's native automatic signing and never passes Apple ID credentials to a
third-party tool. Generation clears its build directory so vendored dependency
caches cannot retain a conflicting CMake generator.

## Repository layout

- `engine/stratagus/` — staged, revision-locked Stratagus source
- `game/wargus/` — staged, revision-locked Wargus data-layer source
- `platform/apple/` — shared macOS/iPadOS platform integration
- `assets/aleonas-tales/` — verified libre content only
- `cmake/` — build modules and Apple toolchains
- `third_party/` — dependency locks and build recipes, not downloaded output
- `tests/` — native, cross-compile, path, input, and gameplay checks
- `scripts/` — reproducible developer and CI entry points
- `config/inputs.lock` — authoritative input and toolchain manifest
- `LICENSES/` and `NOTICE` — licensing and content-boundary records

Engine source and libre assets will be staged from verified inputs only after
their exact revisions and licenses have been recorded. Build products,
runtime state, signing credentials, and proprietary data are ignored.
