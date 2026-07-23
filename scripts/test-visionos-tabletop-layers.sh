#!/bin/zsh
# test-visionos-tabletop-layers.sh
#
# Compiles and runs the framework-free 2.5D board-layer unit tests on the host
# Mac with a plain swiftc invocation (no visionOS Simulator required).
# Tests cover: non-coplanar layer elevations, substrate footprint math, the
# thick substrate slab geometry, board readiness, and stale atlas-completion
# rejection.
set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: ./scripts/test-visionos-tabletop-layers.sh

Compiles and runs the framework-free tabletop board-layer unit tests on the
host Mac.  Requires: swiftc (Xcode command-line tools).
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then usage; exit 0; fi
if (( $# != 0 )); then usage >&2; exit 2; fi

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$ROOT_DIR/build/tabletop-tests/tabletop_layers_test"

command -v swiftc >/dev/null 2>&1 || {
  print -u2 "swiftc is unavailable; install the Swift toolchain (Xcode) first"
  exit 1
}

mkdir -p "${TEST_BINARY:h}"

swiftc \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopMapFit.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopBoardLayers.swift" \
  "$ROOT_DIR/tests/tabletop_layers_test.swift" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
