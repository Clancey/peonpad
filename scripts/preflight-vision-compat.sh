#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
BUILD_DIR="$ROOT_DIR/build/preflight-vision-compat"
TOOLCHAIN="$ROOT_DIR/cmake/toolchains/ios-simulator-arm64.cmake"

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--help" ]]; }; then
  print -u2 "Usage: ./scripts/preflight-vision-compat.sh"
  exit 2
fi
if (( $# == 1 )); then
  print "Usage: ./scripts/preflight-vision-compat.sh"
  exit 0
fi

print "PeonPad Designed-for-iPad Vision Pro compatibility preflight"
print "Workspace: $ROOT_DIR"
print

"$SCRIPT_DIR/preflight.sh"

IPHONE_SIMULATOR_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path) || {
  print -u2 "iPhoneSimulator SDK is unavailable"
  exit 1
}
XR_SIMULATOR_SDK=$(xcrun --sdk xrsimulator --show-sdk-path) || {
  print -u2 "visionOS Simulator SDK is unavailable"
  exit 1
}
VISION_UDID=$("$SCRIPT_DIR/find-vision-pro-simulator.sh")

cmake --fresh -S "$ROOT_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DPEONPAD_ENABLE_ENGINE=OFF >/dev/null
cmake --build "$BUILD_DIR" >/dev/null

PROBE="$BUILD_DIR/libpeonpad_toolchain_probe.a"
lipo -info "$PROBE" | grep -q 'architecture: arm64' || {
  print -u2 "Vision compatibility probe is not arm64"
  exit 1
}
otool -l "$PROBE" | grep -q 'platform 7' || {
  print -u2 "Vision compatibility probe is not an iOS Simulator binary"
  exit 1
}

print
print "Vision compatibility preflight passed:"
print "  app SDK:      $IPHONE_SIMULATOR_SDK"
print "  runtime SDK:  $XR_SIMULATOR_SDK"
print "  destination:  platform=visionOS Simulator,id=$VISION_UDID"
print "  binary:       arm64 iOS Simulator (platform 7)"
print
print "This validates the Designed-for-iPad simulator toolchain, not Vision Pro hardware."
