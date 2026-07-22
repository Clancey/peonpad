#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: ./scripts/test-visionos-tabletop-gameplay.sh

Compiles and runs the framework-independent gameplay snapshot model and
command reducer tests on the host Mac with a plain swiftc invocation (no
visionOS Simulator required). This is the pure-logic layer behind the
tabletop gameplay slice: versioned Codable snapshot, terrain, fog-of-war,
unit roster, selection, and deterministic command reduction.
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
TEST_BINARY="$ROOT_DIR/build/tabletop-tests/tabletop_gameplay_state_test"

command -v swiftc >/dev/null 2>&1 || {
  print -u2 "swiftc is unavailable; install the Swift toolchain (Xcode) first"
  exit 1
}

mkdir -p "${TEST_BINARY:h}"

swiftc \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGestureState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGameplayState.swift" \
  "$ROOT_DIR/tests/tabletop_gameplay_state_test.swift" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
