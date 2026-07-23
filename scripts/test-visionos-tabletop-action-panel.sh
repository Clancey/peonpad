#!/bin/zsh
# test-visionos-tabletop-action-panel.sh
#
# Compiles and runs the framework-free floating-action-panel model tests on the
# host Mac with a plain swiftc invocation (no visionOS Simulator required).
# Covers action enablement vs. selection, exact production-command forwarding,
# the move affordance, dead-selection safety, and unit-ident name mapping.
set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: ./scripts/test-visionos-tabletop-action-panel.sh

Compiles and runs the framework-free tabletop floating-action-panel model unit
tests on the host Mac. Requires: swiftc (Xcode command-line tools).
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then usage; exit 0; fi
if (( $# != 0 )); then usage >&2; exit 2; fi

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$ROOT_DIR/build/tabletop-tests/tabletop_action_panel_test"

command -v swiftc >/dev/null 2>&1 || {
  print -u2 "swiftc is unavailable; install the Swift toolchain (Xcode) first"
  exit 1
}

mkdir -p "${TEST_BINARY:h}"

swiftc \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGestureState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGameplayState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopActionPanel.swift" \
  "$ROOT_DIR/tests/tabletop_action_panel_test.swift" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
