#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: ./scripts/test-visionos-tabletop-harness.sh

Compiles and runs the framework-independent command-integration-harness tests on
the host Mac with a plain swiftc invocation (no visionOS Simulator required).
Tests cover: harness enablement gating (disabled unless the opt-in env var is
set) and the select -> move -> stop state machine that only advances when it
observes the engine's state change in a later snapshot. No engine, C interop,
RealityKit, or proprietary data needed.
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# != 0 )); then
  usage >&2
  exit 2
fi

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$ROOT_DIR/build/tabletop-tests/tabletop_command_harness_test"

command -v swiftc >/dev/null 2>&1 || {
  print -u2 "swiftc is unavailable; install the Swift toolchain (Xcode) first"
  exit 1
}

mkdir -p "${TEST_BINARY:h}"

swiftc \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGestureState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGameplayState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopTransport.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopCommandHarness.swift" \
  "$ROOT_DIR/tests/tabletop_command_harness_test.swift" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
