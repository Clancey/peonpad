# PeonPad macOS baseline procedure

Goal 1 proves that the project source—not the supplied application binary—can
run both required content paths while all mutable state stays outside `ref/`.
Goal 0 must pass first.

## 1. Lock and stage inputs

Record full Git revisions and licenses in `config/inputs.lock`, update the
reference tree digest, and run:

```sh
./scripts/preflight.sh
./scripts/stage-locked-inputs.sh
```

The staging command verifies all inputs before creating destinations, rejects
dirty or mismatched reference repositories, scans for forbidden proprietary
files, and exports only files tracked by the locked Git commit. It rejects
unrecorded submodules and never writes inside `ref/`.

## 2. Build the native engine

Run the canonical two-stage superbuild:

```sh
./scripts/build-macos.sh
```

It builds Stratagus first, then configures Wargus against that exact engine and
its game-launcher headers. It uses the revision-locked vendored Lua 5.1, SDL2,
SDL2_image, SDL2_mixer, zlib, libpng, bzip2, Ogg/Vorbis, Theora, StormLib, and
support libraries. It does not download dependencies.

The canonical runtime output is:

```text
build/macos/stratagus
```

The Wargus outputs are `build/macos/wargus/wargus`, `wartool`, and
`pudconvert`. All four executables are arm64, target macOS 13.0, use the Xcode
26.5 SDK, and do not link into `ref/`.

The staged-source patches under `patches/` make the old dependency CMake files
safe with Xcode 26: Apple platform flags propagate into nested builds, archived
`zconf.h` files remain unchanged, modern Apple targets avoid classic-Mac
headers, arm64 libpng uses NEON directly, and SDL's valid C99 HIDAPI code is no
longer rejected by an obsolete warning-as-error probe. They also enable the
vendored dr_flac decoder and distinguish Ogg/FLAC from Ogg/Vorbis, which is
required because the extracted WC2 music uses FLAC streams in `.ogg`
containers. All patches apply cleanly to the locked reference revisions.

Relative editor-map output is routed to the per-game user directory. Matching
map lookup and non-stale path caching allow Wargus Random Skirmish to save and
reload its generated map without writing into the read-only data tree.

Meaningful remaining build warnings are upstream deprecations (`sprintf`, old
AppKit/CoreVideo APIs, pre-C23 C definitions), plus duplicate static-library
linker entries. None prevented the native build or introduced a reference
dependency.

## 3. Run with isolated writable state

The reference Stratagus CLI confirms these relevant options:

- `-d datapath`: read-only game-data location
- `-u userpath`: preferences, command log, and savegame location

Run the licensed-data path:

```sh
./scripts/run-macos.sh --profile wc2 -- -W
```

Run the libre path:

```sh
./scripts/run-macos.sh --profile aleona -- -W
```

The wrapper rejects executables under `ref/`, supplies explicit `-d` and `-u`
paths, redirects HOME/cache/temp state into `runtime/macos/<profile>/`, captures
the console log, and compares the complete reference digest before and after a
WC2 run.

## Acceptance evidence

Current automated evidence (July 10, 2026):

- `./scripts/build-macos.sh` succeeds from the root superbuild.
- The canonical engine reports Stratagus 3.3.3 with ZLIB, BZ2LIB, Vorbis,
  Theora, and macOS support compiled in.
- Both WC2 and Aleona's Tales load their scripts and remain in the running main
  loop for a headless smoke check.
- Aleona's Tales emitted only the expected first-run missing
  `preferences.lua` warning.
- The decoder inventory includes DRFLAC/FLAC, and the WC2 smoke log no longer
  contains `LoadMusic` or `PlayMusic` failures for the extracted Ogg/FLAC
  tracks while using SDL's dummy output device.
- The locked `ref/` digest remained unchanged through preflight, build, smoke,
  and interactive runs.

Interactive acceptance evidence (July 10, 2026):

- WC2: launched the PeonPad-built arm64 executable with
  `ref/data.Wargus`, started Skirmish Classic, selected and moved units, saved
  `game.sav.gz`, then loaded it back into the match. The save is isolated at
  `runtime/macos/wc2-app/user/wc2/save/game.sav.gz`.
- Aleona's Tales: started Skirmish Classic from the staged asset snapshot,
  selected and moved workers, saved `game.sav.gz`, then loaded it back into the
  match. The save is isolated at
  `runtime/macos/aleona-app/user/wc2/save/game.sav.gz`.
- Random Skirmish: from a fresh WC2 profile, generated and entered a live map.
  `randommap.smp`, `randommap.sms`, and `randommap.png` appeared only beneath
  `runtime/macos/wc2-random-safe-2/user/wc2/maps/`. The complete `ref/` digest
  remained exactly
  `c1782ea011559049ce65b739c6cbe5825a4db3b1c8d2afaea0dbcb54e7357f8f`.

The Phase 0 gameplay acceptance test is satisfied for both content paths.
Audible output on a physical CoreAudio device remains a hardware-session check:
this remote session exposes no live output device, but decoding and playback
submission now pass with SDL's dummy device.

The supplied `ref/Wargus.app` can provide behavioral evidence and CLI
documentation, but it cannot satisfy the build-from-source acceptance test.
