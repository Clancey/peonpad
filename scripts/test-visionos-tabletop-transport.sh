#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: ./scripts/test-visionos-tabletop-transport.sh

Compiles PeonPadTabletopBridge (C++17) and the Swift transport files on the
host Mac, links them together, and runs the integration test suite.

Tests cover: C→Swift snapshot conversion, ABI validation, retain/release
ownership, all five command types, command round-trip (post → bridge accepts),
engine lifecycle start/stop, and data-path resolution.

No visionOS Simulator required; all tests run as a native macOS binary.
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
BRIDGE_SRC="$ROOT_DIR/platform/bridge"
TABLETOP_SRC="$ROOT_DIR/platform/apple/visionos/tabletop"
BUILD_DIR="$ROOT_DIR/build/tabletop-transport-tests"
BRIDGE_OBJ="$BUILD_DIR/PeonPadTabletopBridge.o"
TEST_BINARY="$BUILD_DIR/tabletop_transport_test"

command -v swiftc >/dev/null 2>&1 || {
  print -u2 "swiftc unavailable; install Xcode/Swift toolchain first"
  exit 1
}

mkdir -p "$BUILD_DIR"

# ── Compile the C bridge for the host Mac (no visionOS SDK needed) ─────────
clang++ \
  -std=c++17 \
  -O0 -g \
  -I "$BRIDGE_SRC" \
  -c "$BRIDGE_SRC/PeonPadTabletopBridge.cpp" \
  -o "$BRIDGE_OBJ"

# ── Compile Swift sources and link with the C bridge ────────────────────────
swiftc \
  -I "$BRIDGE_SRC" \
  -Xcc -I"$BRIDGE_SRC" \
  "$TABLETOP_SRC/TabletopGestureState.swift" \
  "$TABLETOP_SRC/TabletopGameplayState.swift" \
  "$TABLETOP_SRC/TabletopTransport.swift" \
  "$TABLETOP_SRC/TabletopGameplaySource.swift" \
  "$TABLETOP_SRC/TabletopDataPaths.swift" \
  "$TABLETOP_SRC/TabletopEngineLifecycle.swift" \
  "$TABLETOP_SRC/TabletopEngineTransport.swift" \
  "$ROOT_DIR/tests/tabletop_transport_test.swift" \
  "$BRIDGE_OBJ" \
  -lc++ \
  -o "$TEST_BINARY"

"$TEST_BINARY"
