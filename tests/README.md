# Verification strategy

Tests progress from native compiler and immutable-input checks to macOS
gameplay, iOS static-library architecture checks, sandbox path tests, touch and
Pencil gesture tests, and physical-device acceptance runs. A narrow probe does
not satisfy a later gameplay acceptance gate.

`script-guardrails.sh` uses a fake engine to prove that the macOS launcher
rejects binaries inside `ref/`, passes separate data and user paths, redirects
HOME/cache/temp state, and preserves the complete reference digest. It does
not substitute for either Goal 1 gameplay run. It also validates the iOS
launch/icon declarations, exact opaque PNG dimensions, and the complete
ordered Stratagus patch series.

`scripts/test-ios-viewport.sh` compiles the pure C++ Apple viewport geometry on
the host in Release mode with `-DNDEBUG`. Explicit checks cover default, wide,
tall, Retina, repeated resize, asymmetric insets, invalid geometry, inverse
input mapping, and points in letterbox/pillarbox bars. Device acceptance remains
necessary to verify the live UIKit insets and rendered result on the target.

The default CTest configuration also builds `peonpad_input_intent_test`. It
checks platform-neutral pointer, key, context-action, viewport-pan, and game
controller intent phases without requiring game data. Controller coverage
includes device-registry duplication and handoff, radial dead zones and curves,
frame-rate-independent bounded cursor motion, camera-axis zeroing, held
modifier cleanup, gameplay/menu context changes, menu repeat, SDL2 mapping,
valid input after cancellation, and source-owned primary/context buttons so a
controller release or cancellation cannot clear an overlapping mouse or touch
hold.

`scripts/preflight-vision-compat.sh` runs the public baseline, checks the
iPhoneSimulator and visionOS Simulator SDKs plus an available Vision Pro
runtime, then compiles an arm64 iOS Simulator platform-7 probe. The full
Designed-for-iPad build and optional launch are exercised separately by
`scripts/build-vision-compat-simulator.sh`; neither substitutes for Vision Pro
hardware acceptance.

The opt-in SDL3 CTest configuration adds `peonpad_sdl3_input_adapter` and
`peonpad_sdl3_foundation`. These compile the SDL3 event adapter against the
existing controller/touch intent state and run a headless SDL3 core,
SDL3_image, SDL3_mixer, filesystem, renderer, texture, and gamepad smoke
payload. `scripts/build-sdl3-foundation.sh macos` additionally runs the native
Metal/window-properties path; simulator targets are compile/link evidence.

`scripts/build-visionos-shell.sh` separately builds and inspects the complete
native xros/xrsimulator shell configuration. Its launch route verifies an Apple
Vision Pro under a visionOS runtime, install, launch PID residency, and optional
local screenshot evidence. Guardrails also compile the layered visionOS icon
catalog and exercise wrong-runtime simulator override rejection.
