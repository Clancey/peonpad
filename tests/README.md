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

`scripts/test-ios-viewport.sh` compiles the pure C++ iOS viewport geometry on
the host and checks full-screen 4:3, asymmetric safe insets, aspect fitting,
and invalid geometry. Device acceptance remains necessary to verify the live
UIKit insets and rendered result on the target iPad.

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
