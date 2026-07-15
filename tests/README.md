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
checks platform-neutral pointer, key, context-action, and viewport-pan intent
phases, propagation, cancellation, and the pure multi-touch gesture state
without requiring game data.
