#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$ROOT_DIR/build/tabletop-tests/tabletop_launcher_model_test"

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  print "Usage: ./scripts/test-visionos-tabletop-launcher.sh"
  exit 0
fi
if (( $# != 0 )); then
  print -u2 "Usage: ./scripts/test-visionos-tabletop-launcher.sh"
  exit 2
fi

mkdir -p "${TEST_BINARY:h}"
swiftc \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopLauncherModel.swift" \
  "$ROOT_DIR/platform/apple/visionos/tabletop/EngineStartupPlan.swift" \
  "$ROOT_DIR/tests/tabletop_launcher_model_test.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY"
