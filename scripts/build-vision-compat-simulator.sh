#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${PEONPAD_VISION_COMPAT_BUILD_DIR:-$ROOT_DIR/build/ios-vision-compat}
BUILD_DIR=${BUILD_DIR:A}
DATA_DIR=${PEONPAD_IOS_DATA_DIR:-$ROOT_DIR/build/ios-wc2-data}
TOOLCHAIN="$ROOT_DIR/cmake/toolchains/ios-simulator-arm64.cmake"
HOST_TOLUA=${STRATAGUS_HOST_TOLUAPP:-$ROOT_DIR/build/macos/engine/lua/src/lua-build/toluapp}
LAUNCH=0

if (( $# > 1 )); then
  print -u2 "Usage: ./scripts/build-vision-compat-simulator.sh [--launch]"
  exit 2
fi
if (( $# == 1 )); then
  case "$1" in
    --help)
      print "Usage: ./scripts/build-vision-compat-simulator.sh [--launch]"
      exit 0
      ;;
    --launch)
      LAUNCH=1
      ;;
    *)
      print -u2 "Usage: ./scripts/build-vision-compat-simulator.sh [--launch]"
      exit 2
      ;;
  esac
fi

case "$BUILD_DIR/" in
  "$ROOT_DIR/build/"*) ;;
  *)
    print -u2 "Vision compatibility build directory must be inside $ROOT_DIR/build: $BUILD_DIR"
    exit 1
    ;;
esac

[[ -x "$HOST_TOLUA" ]] || {
  print -u2 "missing host tolua generator; run ./scripts/build-macos.sh first"
  exit 1
}
[[ -f "$DATA_DIR/scripts/stratagus.lua" ]] || {
  print -u2 "missing iOS data payload: $DATA_DIR"
  print -u2 "stage owned Warcraft II data with ./scripts/stage-ios-wc2-test-data.sh"
  exit 1
}
if [[ "${PEONPAD_DISTRIBUTION_BUILD:-0}" == 1 ]]; then
  [[ "$DATA_DIR" == "$ROOT_DIR/assets/aleonas-tales/source" ]] || {
    print -u2 "distribution builds cannot embed a private game-data payload"
    exit 1
  }
  "$SCRIPT_DIR/audit-aleona-assets.sh" --strict
elif [[ "$DATA_DIR" == "$ROOT_DIR/assets/aleonas-tales/source" ]]; then
  "$SCRIPT_DIR/audit-aleona-assets.sh" --local-test
fi
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null || {
  print -u2 "iPhoneSimulator SDK is unavailable"
  exit 1
}
xcrun --sdk xrsimulator --show-sdk-path >/dev/null || {
  print -u2 "visionOS Simulator SDK is unavailable"
  exit 1
}
VISION_UDID=$("$SCRIPT_DIR/find-vision-pro-simulator.sh")

cmake -E remove_directory "$BUILD_DIR"
cmake --fresh -S "$ROOT_DIR/engine/stratagus" -B "$BUILD_DIR" \
  -G Xcode \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DBUILD_VENDORED_LUA=ON \
  -DBUILD_VENDORED_SDL=ON \
  -DBUILD_VENDORED_MEDIA_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DDOWNLOAD_FREEPATS=OFF \
  -DENABLE_DEV=OFF \
  -DENABLE_DOC=OFF \
  -DWITH_OPENMP=OFF \
  -DWITH_STACKTRACE=OFF \
  -DHAVE_STRCPYS=OFF \
  -DHAVE_STRNCPYS=OFF \
  -DSTRATAGUS_HOST_TOLUAPP="$HOST_TOLUA" \
  -DPEONPAD_IOS_INFO_PLIST="$ROOT_DIR/platform/apple/ios/Info.plist.in" \
  -DPEONPAD_IOS_DATA_DIR="$DATA_DIR" \
  -DPEONPAD_IOS_LAUNCH_IMAGE="$ROOT_DIR/platform/apple/ios/PeonPadLaunch.png" \
  -DPEONPAD_IOS_ICON_DIR="$ROOT_DIR/platform/apple/ios" \
  -DPEONPAD_APPLE_PLATFORM_DIR="$ROOT_DIR/platform/apple"

PROJECT="$BUILD_DIR/stratagus.xcodeproj"
DESTINATION="platform=visionOS Simulator,id=$VISION_UDID"
xcodebuild -project "$PROJECT" -scheme stratagus -configuration Release \
  -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO build

APP="$BUILD_DIR/Release-iphonesimulator/PeonPad.app"
EXECUTABLE="$APP/PeonPad"
[[ -f "$EXECUTABLE" ]] || {
  print -u2 "missing Vision compatibility app executable: $EXECUTABLE"
  exit 1
}
lipo -info "$EXECUTABLE" | grep -q 'architecture: arm64' || {
  print -u2 "Vision compatibility app is not arm64"
  exit 1
}
otool -l "$EXECUTABLE" | awk '
  $1 == "platform" {platform = $2}
  $1 == "minos" {minos = $2}
  END {exit platform != 7 || minos != "16.0"}
' || {
  print -u2 "app is not an iOS 16.0 Simulator binary"
  exit 1
}
[[ "$(plutil -extract UIDeviceFamily.0 raw "$APP/Info.plist")" == "2" ]] || {
  print -u2 "Vision compatibility app is not iPad-only"
  exit 1
}

PROPRIETARY_HIT=$(find "$APP" \
  \( -type d -iname 'data.Wargus' \
  -o -type f \( -iname '*.mpq' -o -iname 'INSTALL.EXE' \
  -o -iname 'WAR2DAT.MPQ' \) \) -print -quit)
[[ -z "$PROPRIETARY_HIT" ]] || {
  print -u2 "proprietary extraction input found in app: $PROPRIETARY_HIT"
  exit 1
}

print
print "PeonPad Designed-for-iPad compatibility app built successfully:"
print "  app:          $APP"
print "  executable:   arm64 iOS Simulator 16.0 (platform 7)"
print "  destination:  $DESTINATION"
print "  xros target:  no"

if (( LAUNCH )); then
  STATE=$(xcrun simctl list devices | awk -v id="$VISION_UDID" '
    !found && index($0, id) {
      found = 1
      if ($0 ~ /\(Booted\)/) print "Booted"
      else if ($0 ~ /\(Shutdown\)/) print "Shutdown"
      else print "Unknown"
    }
  ')
  case "$STATE" in
    Booted) ;;
    Shutdown) xcrun simctl boot "$VISION_UDID" ;;
    *)
      print -u2 "unexpected Vision Pro simulator state: ${STATE:-missing}"
      exit 1
      ;;
  esac
  xcrun simctl bootstatus "$VISION_UDID" -b
  xcrun simctl install "$VISION_UDID" "$APP"
  xcrun simctl launch --terminate-running-process \
    "$VISION_UDID" org.peonpad.ios
  print "  launch:       requested successfully"
fi

print
print "Simulator success does not satisfy Vision Pro hardware acceptance."
