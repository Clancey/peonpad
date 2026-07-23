#!/bin/zsh
# test-visionos-tabletop-navigation.sh
#
# Compiles and runs the framework-free indirect (mouse/trackpad) navigation
# reducer tests on the host Mac with a plain swiftc invocation (no visionOS
# Simulator required).  Tests cover: pan/zoom/rotate mapping and clamping, and
# board-transform persistence when a physical hand gesture resumes after
# indirect navigation (no jump).
set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: ./scripts/test-visionos-tabletop-navigation.sh

Compiles and runs the framework-free tabletop indirect-navigation unit tests on
the host Mac.  Requires: swiftc (Xcode command-line tools).
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then usage; exit 0; fi
if (( $# != 0 )); then usage >&2; exit 2; fi

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$ROOT_DIR/build/tabletop-tests/tabletop_navigation_test"

command -v swiftc >/dev/null 2>&1 || {
  print -u2 "swiftc is unavailable; install the Swift toolchain (Xcode) first"
  exit 1
}

mkdir -p "${TEST_BINARY:h}"

swiftc \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGestureState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopIndirectNavigation.swift" \
  "$ROOT_DIR/tests/tabletop_navigation_test.swift" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
