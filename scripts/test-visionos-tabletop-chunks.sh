#!/bin/zsh
# test-visionos-tabletop-chunks.sh
#
# Compiles and runs the framework-independent chunk-geometry tests on the host
# Mac with a plain swiftc invocation (no visionOS Simulator required).
# Tests cover: chunk partitioning, atlas slot mapping, mesh geometry, UV
# layout, fog-map pixel state, cgImage creation, and entity-count reduction.
set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: ./scripts/test-visionos-tabletop-chunks.sh

Compiles and runs the framework-free tabletop chunk-geometry unit tests on the
host Mac.  Requires: swiftc (Xcode command-line tools).
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then usage; exit 0; fi
if (( $# != 0 )); then usage >&2; exit 2; fi

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$ROOT_DIR/build/tabletop-tests/tabletop_chunk_geometry_test"

command -v swiftc >/dev/null 2>&1 || {
  print -u2 "swiftc is unavailable; install the Swift toolchain (Xcode) first"
  exit 1
}

mkdir -p "${TEST_BINARY:h}"

swiftc \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopMapFit.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGestureState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGameplayState.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopChunkGeometry.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopTerrainAtlasImage.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopChunkReadiness.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopFogMap.swift" \
  "$ROOT_DIR/tests/tabletop_chunk_geometry_test.swift" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
