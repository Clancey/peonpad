# Direct SDL3 foundation

SDL2 remains PeonPad's default and accepted application path. The direct SDL3
lane is enabled only with `PEONPAD_ENABLE_SDL3=ON`; it deliberately refuses a
same-config `PEONPAD_ENABLE_ENGINE=ON` build until the full Stratagus port is
complete. No sdl2-compat code or SDL fork is present.

## Locked inputs

| Dependency | Release | Commit | Archive SHA-256 |
| --- | --- | --- | --- |
| SDL | 3.4.12 | `f87239e71e42da91ca317a12eefb82cfbf3393eb` | `b68381f06a7580e63400b3b6eb547ec57d8c3ebde70f9f40e0aba530ba05da27` |
| SDL_image | 3.4.4 | `bec9134a26c7d0f31b36d6083c25296e04cabff5` | `b0c11bbde540e26d1cedf31174349fe6ab67e57658efe22e16e75172859c817d` |
| SDL_mixer | 3.2.4 | `72a81869b45e249e8e67102db4e98dd2441f05a1` | `f2ea848ccdf2f394cd4973ee0f6c482e04511044695cccfd46bab6dcd7f780aa` |

The Zlib-licensed release archives are committed under
`third_party/sdl3/sources`. CMake reads only those local archives. Run
`scripts/verify-sdl3-sources.sh` to verify their immutable hashes.

## SDL2 application inventory

The staged Stratagus application uses SDL in 53 source/header files, plus the
Apple safe-area bridge. The highest-impact files are `src/video/sdl.cpp`,
`src/video/graphic.cpp`,
`src/sound/sound_server.cpp`, `src/video/movie.cpp`, and
`src/video/shaders.cpp`.

| Group | Current SDL2 APIs and behavior | Direct SDL3 requirement |
| --- | --- | --- |
| Entry/lifecycle | `main`, `SDL_Init`, `SDL_InitSubSystem`, `SDL_Quit`, `SDL_WasInit`, `SDL_APP_*`, `SDL_QUIT` | SDL main callbacks, boolean init results, `SDL_EVENT_*`, event watches for background/termination |
| Events/text | `SDL_PollEvent`, `SDL_PeepEvents`, `SDL_PushEvent`, key/mouse/window/touch events, `SDL_StartTextInput`, `SDL_StopTextInput` | New event constants and fields; text input now takes a window; finger cancellation is `SDL_EVENT_FINGER_CANCELED` |
| Controller | `SDL_NumJoysticks`, `SDL_IsGameController`, open/close/name/instance ownership, controller axis/button/device events | `SDL_GetGamepads`, instance-ID `SDL_OpenGamepad`, `SDL_Gamepad*`, `event.down`; preserve the existing intent/state adapter and GCEventInteraction ownership |
| Renderer/window | create/destroy window, renderer, texture; logical size, scale, viewport, output size, draw/copy/present/read pixels, high-DPI/fullscreen/grab | `SDL_SetRenderLogicalPresentation`, float render geometry, boolean returns, pixel-size APIs, SDL3 renderer properties |
| Surfaces/pixels | create/from/convert/free/lock/blit/fill, palettes, color keys/modulation, map/get RGB(A), clip rects | SDL3 surface constructors and embedded pixel-format details; `SDL_MapSurfaceRGB(A)` and changed conversion signatures |
| Images | `IMG_Init`, `IMG_Quit`, `IMG_Load_RW`, `IMG_SavePNG` | no image init phase; `SDL_IOStream`, `IMG_Load_IO`; boolean save results |
| Audio | classic `Mix_Chunk`/`Mix_Music`, global channels/music, decoder enumeration, panning, volume, callbacks, RW loaders | `MIX_Mixer`, `MIX_Audio`, reusable `MIX_Track`, properties and explicit object ownership; this is the largest remaining subsystem rewrite |
| Filesystem | `SDL_GetBasePath`, `SDL_GetPrefPath`, SDL environment allocation/free | APIs remain, with SDL3 ownership and boolean-return auditing |
| Native Apple window | `SDL_SysWMinfo`/`SDL_GetWindowWMInfo` in the iOS safe-area bridge | `SDL_GetWindowProperties` plus `SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER` or `SDL_PROP_WINDOW_COCOA_WINDOW_POINTER` |
| GL/video tools | GL procedure/swap/bind APIs, YUV textures, legacy overlay references, clipboard, dynamic loading | audit renderer-vs-GL ownership and replace removed overlay/format calls |

The exact symbol inventory is reproducible without scanning vendored libraries:

```sh
rg -o --no-filename --glob '*.{c,cc,cpp,cxx,h,hpp,m,mm}' \
  '\b(?:SDL|IMG|Mix)_[A-Za-z0-9_]+' engine/stratagus/src \
  | sort -u
```

Wargus tools do not call SDL directly; they consume the linked Stratagus
launcher/engine interfaces.

## Foundation coverage

The smoke payload uses SDL3 main callbacks and directly exercises core
initialization, lifecycle events, base/pref paths, image decode, the SDL_mixer
3 object model and decode/memory mixing, renderer logical letterboxing,
textures/surfaces/pixels, text input, gamepad instance discovery/ownership, and
the supported Apple native-window properties. The SDL3 input adapter maps
gamepad/touch/focus events into the existing controller and touch intent state,
including cancellation and multi-source ownership behavior.

Build each lane without proprietary data:

```sh
./scripts/build-sdl3-foundation.sh macos
./scripts/build-sdl3-foundation.sh ios-simulator
./scripts/build-sdl3-foundation.sh xrsimulator
./scripts/build-visionos-shell.sh xrsimulator --launch
./scripts/build-visionos-shell.sh xros
```

Evidence captured July 15, 2026:

| Lane | Result |
| --- | --- |
| macOS 13 arm64 | All foundation targets built, and the callback payload ran with both software and Metal renderers and reported exact core `3.4.12`, image `3.4.4`, and mixer `3.2.4` runtime versions. |
| iOS Simulator 16 arm64 | All foundation targets, including the toolchain probe and input adapter, compiled; the SDL3-family payload and Apple bridge linked as Mach-O platform 7 with SDK 26.5. |
| visionOS Simulator 2 arm64 | All foundation and native shell targets compiled as Mach-O platform 12 with SDK 26.5. The app installed, launched, remained resident, and rendered its public smoke card on Apple Vision Pro / visionOS 26.5. |
| visionOS device 2 arm64 | The complete unsigned xros configuration built as Mach-O platform 11 with SDK 26.5. Xcode team signing and available paired hardware remain manual gates. |
| Default SDL2 | The full macOS Stratagus/Wargus app and tools built, and the default input/guardrail CTests passed. |

The native xrsimulator build currently emits upstream SDL/SDL_image warnings
for deprecated Uniform Type APIs and conditionally unused UIKit/Metal symbols.
They remain visible and are not suppressed.

The xrsimulator lane now has native scene ownership, bundle metadata, a
resizable UIKit/Metal window, and runtime shell acceptance. It remains only the
public SDL3 smoke payload. A later stacked PR must port the remaining engine
renderer, surface/pixel, SDL_image I/O, SDL_mixer playback, event loop, and tool
call sites before enabling `PEONPAD_ENABLE_ENGINE`. Audio-session, Vision Pro
controller/input, comfort, and gameplay acceptance remain unclaimed.
