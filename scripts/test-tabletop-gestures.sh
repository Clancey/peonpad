#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
BUILD_DIR="$ROOT_DIR/build/tabletop-gesture-tests"
TEST_BINARY="$BUILD_DIR/tabletop-gesture-state-test"

cmake -E remove_directory "$BUILD_DIR"
cmake -E make_directory "$BUILD_DIR"
xcrun swiftc -parse-as-library -O \
  "$ROOT_DIR/platform/apple/visionos/tabletop/TabletopGestureState.swift" \
  "$ROOT_DIR/tests/tabletop_gesture_state_test.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY"
