# Direct SDL3 engine lane

SDL2 remains PeonPad's default and hardware-accepted application path. The
opt-in combination

```sh
-DPEONPAD_ENABLE_ENGINE=ON -DPEONPAD_ENABLE_SDL3=ON
```

now builds the complete staged Stratagus engine directly against SDL 3.4.12,
SDL_image 3.4.4, and SDL_mixer 3.2.4. It also builds the native Wargus launcher
and host tools on macOS. No sdl2-compat code, SDL fork, or backport is present.

## Locked inputs

| Dependency | Release | Commit | Archive SHA-256 |
| --- | --- | --- | --- |
| SDL | 3.4.12 | `f87239e71e42da91ca317a12eefb82cfbf3393eb` | `b68381f06a7580e63400b3b6eb547ec57d8c3ebde70f9f40e0aba530ba05da27` |
| SDL_image | 3.4.4 | `bec9134a26c7d0f31b36d6083c25296e04cabff5` | `b0c11bbde540e26d1cedf31174349fe6ab67e57658efe22e16e75172859c817d` |
| SDL_mixer | 3.2.4 | `72a81869b45e249e8e67102db4e98dd2441f05a1` | `f2ea848ccdf2f394cd4973ee0f6c482e04511044695cccfd46bab6dcd7f780aa` |

The Zlib-licensed release archives are committed under
`third_party/sdl3/sources`. CMake reads only those local archives.
`scripts/verify-sdl3-sources.sh` checks their immutable hashes.

The canonical staged Stratagus tree is reconstructed by ordered patches
`0001` through `0010-direct-sdl3-engine.patch`. Its tracked-tree SHA-256 is
`9c8710b17b62f9fa775c2c002b5bfb1787811b515c7e881a4ccc268d17a2548e`.
The stage script, public preflight, and reverse/reapply guardrail all enforce
that value.

## Ported engine surface

Version differences are concentrated in `sdl_compat.h`, `sdl_gl_compat.h`,
the SDL3 include facade under `platform/sdl3/include`, the reviewed input and
Apple-window adapters, and the typed mixer adapter. Gameplay code continues to
use the engine's established abstractions.

| Area | Direct SDL3 implementation |
| --- | --- |
| Lifecycle and events | Initialization and shutdown, polling and pushed user events, focus, background, foreground, termination, text input, clipboard, cursor visibility, and Apple safe-area refresh use SDL3's boolean results and `SDL_EVENT_*` model. Pointer and finger events pass through `SDL_ConvertEventToRenderCoordinates` before gameplay or Guisan dispatch; begins in safe-area or aspect bars are rejected while releases still perform ownership cleanup. |
| Windows and rendering | Window, renderer, texture, logical-presentation, drawable-pixel, viewport, render-target, readback, copy, clear, and present behavior is adapted with checked SDL3 results and typed integer-to-float geometry conversion. Apple engine rendering disables SDL logical presentation before applying one uniform safe-area scale and logical-coordinate viewport, avoiding composed double scaling. |
| Surfaces and pixels | Owned and preallocated surfaces, embedded pixel-format details, indexed palettes, palette alpha, color keys and modulation, locking, conversion, blitting, filling, clipping, and RGB(A) mapping are covered. |
| Image and file I/O | `CFile` transfers ownership through SDL3 `SDL_IOStream` callbacks; seek, size, read, close, error status, and `IMG_Load_IO` ownership are explicit. Plain, gzip, and bzip2 streams share status-returning seek semantics, preserve position across uncompressed-size queries, and support reliable `SEEK_END`; bzip2 backwards seeks reopen and skip deterministically. SDL_image 3 has no global codec-init phase, so the legacy init/quit calls are isolated compatibility no-ops rather than gameplay fallbacks. |
| Audio and music | `PeonPadSDL3MixerAdapter` maps the engine's channel/music contract to stable `MIX_Mixer`, `MIX_Audio`, and `MIX_Track` objects. It preserves allocation, playback, loops, pause/resume/halt/query, prior-volume returns, panning, callbacks, music ownership, and teardown while propagating mixer failures. Paused tracks remain playing and are not reused as free channels, matching SDL_mixer 2. |
| Controllers and touch | SDL3 gamepad discovery, instance ownership, axis/button/device events, focus cancellation, finger cancellation, and source-aware mouse-button ownership reuse the reviewed intent router. |
| GL, YUV, and movies | YUV texture upload, renderer-backed movie frames, shaders, OpenGL context/swap, and SDL3 OpenGL texture properties are checked. SDL2 retains its existing bind/unbind path. |
| Platform services | Base/pref paths, delays, ticks, environment use, dynamic loading, fullscreen/grab, screenshots, fog, minimap, palette cycling, and Guisan's SDL renderer/surface/input backends compile through the same typed boundary. |
| Tools | Native macOS builds produce Stratagus, Wargus, `wartool`, and `pudconvert`. The Wargus host utilities do not link SDL and remain host-only during Apple cross-compilation; all target/runtime engine code still compiles and links for each Apple SDK. |

## Release-sensitive tests

The macOS SDL3 configuration registers the existing engine suite plus focused
tests that do not depend on disabled C/C++ assertions:

- input cancellation, focus loss, multi-source button overlap, and gamepad
  ownership;
- surface creation/conversion, indexed palettes, preallocated ownership,
  renderer upload/readback, and the OpenGL property boundary;
- plain, gzip, and bzip2 `CFile` size/seek/restoration, descriptor/stream close
  ownership, and SDL IO error behavior;
- mixer initialization, channel allocation, callbacks, volume, panning,
  pause/resume, music replacement, teardown, and failure paths;
- non-unit renderer-coordinate conversion, safe-area bar rejection, and 4:3
  viewport/inverse input mapping under `-DNDEBUG`;
- exact raw readiness output and its explicit failure path.

On July 19, 2026, the clean SDL3 Release tree passed all 74 registered tests.
The clean default SDL2 Release tree passed all four top-level compatibility
tests and built its unchanged vendored SDL2 engine/app/tools lane.

## Reproducible build evidence

The final validation used complete default builds, not selected smoke targets:

```sh
cmake --fresh -S . -B build/validation-sdl3-engine \
  -G "Unix Makefiles" \
  -DPEONPAD_ENABLE_ENGINE=ON \
  -DPEONPAD_ENABLE_SDL3=ON \
  -DBUILD_TESTING=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
cmake --build build/validation-sdl3-engine --parallel
ctest --test-dir build/validation-sdl3-engine --output-on-failure
```

The same all-target configure/build was repeated with each Apple toolchain:

```text
cmake/toolchains/ios-simulator-arm64.cmake
cmake/toolchains/xros-simulator-arm64.cmake
cmake/toolchains/xros-arm64.cmake
```

| Lane | July 19, 2026 result |
| --- | --- |
| macOS 13 arm64, direct SDL3 | Full Stratagus, Wargus, `wartool`, `pudconvert`, app bundle, foundation, adapters, and tests built. All 74 tests passed. The foundation runtime reported the pinned versions with both `renderer=software` and `renderer=metal`. |
| macOS 13 arm64, default SDL2 | Full Stratagus, Wargus, `wartool`, `pudconvert`, and app bundle built as arm64. All four top-level tests passed. |
| iOS Simulator 16 arm64 | The complete SDL3 engine and foundation linked as Mach-O platform 7. Engine and adapter archives are arm64; tolua generation used a separately built native arm64 host executable. |
| visionOS Simulator 2 arm64 | The complete SDL3 engine and native smoke shell linked as Mach-O platform 12. The inspected shell bundle remains the public non-gameplay payload. |
| visionOS device 2 arm64 | The complete SDL3 engine and unsigned native smoke shell linked as arm64 Mach-O platform 11. Bundle inspection passed; no provisioning profile or signing identity was added. |

Public preflight, SDL source/license/hash checks, Release viewport/input checks,
bundle/content scans, and exact patch reverse/reapply reconstruction also
passed without fetching inputs from the network.

## Automation and packaging contract

The native Apple engine resolves legal game scripts beneath
`${SDL_GetBasePath()}/Aleona`. A packaging layer must place the complete
redistribution-approved payload there before launch.

Successful startup writes exactly:

```text
PEONPAD_ENGINE_READY
```

The marker is written as one raw line to process stdout and flushed immediately,
only after `PreMenuSetup()` succeeds. A write or flush failure aborts startup.
Script, asset, surface, renderer, and audio failures remain errors; missing
startup data exits nonzero and does not emit the marker. Automation must treat
process exit before that exact line as failure rather than retaining readiness
from an earlier run.

The current `PeonPadVisionShell.app` intentionally does not package or launch
this engine artifact. A later layer must perform that application integration.

## Deliberately deferred acceptance

This port proves source parity and complete compile/link coverage. It does not
claim native visionOS gameplay, bundled game data, gestures, eye/hand targeting,
audio-session behavior, signing, sustained performance, or physical Vision Pro
acceptance. The smoke shell still displays `SMOKE SHELL — NO GAMEPLAY`.

The native xrsimulator build also retains visible upstream SDL/SDL_image
warnings for deprecated Uniform Type APIs and conditionally unused
UIKit/Metal symbols; they are not suppressed.
