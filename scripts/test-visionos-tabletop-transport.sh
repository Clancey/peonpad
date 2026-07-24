#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: ./scripts/test-visionos-tabletop-transport.sh

Compiles and runs the framework-independent live engine transport tests on the
host Mac with a plain swiftc invocation (no visionOS Simulator required).
Tests cover: EngineSnapshot -> TabletopGameplaySnapshot conversion (ABI guard,
terrain/fog/unit/type mapping, selection), TabletopGameplayCommand ->
EngineCommand lowering, board map-fit geometry, Wargus asset-key mapping, and
engine startup preconditions/argv. No engine, C interop, or RealityKit needed.
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
TEST_BINARY="$ROOT_DIR/build/tabletop-tests/tabletop_transport_conversion_test"

command -v swiftc >/dev/null 2>&1 || {
  print -u2 "swiftc is unavailable; install the Swift toolchain (Xcode) first"
  exit 1
}

mkdir -p "${TEST_BINARY:h}"

swiftc \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGestureState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGameplayState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopTransport.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/EngineTabletopModel.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopSnapshotConverter.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/EngineCommandEncoder.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopMapFit.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/WargusTabletopAssetResolver.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopAssetResolution.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopLauncherModel.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/EngineStartupPlan.swift" \
  "$ROOT_DIR/tests/tabletop_transport_conversion_test.swift" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
