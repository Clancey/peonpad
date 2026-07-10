#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$ROOT_DIR/build/tests/viewport_geometry_test"

mkdir -p "${TEST_BINARY:h}"

${CXX:-c++} -std=c++17 -Wall -Wextra -Werror \
  -I "$ROOT_DIR/platform/apple/ios" \
  "$ROOT_DIR/platform/apple/ios/PeonPadViewportGeometry.cpp" \
  "$ROOT_DIR/tests/viewport_geometry_test.cpp" \
  -o "$TEST_BINARY"

"$TEST_BINARY"
print "iOS safe-area viewport geometry tests passed"
