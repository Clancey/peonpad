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
VISION_UDID=""
ALLOW_USER_SIMULATOR=0

usage() {
  print "Usage: ./scripts/build-vision-compat-simulator.sh [--launch]"
  print "  [--simulator-udid UDID --allow-user-simulator]"
}

while (( $# > 0 )); do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --launch)
      LAUNCH=1
      ;;
    --simulator-udid)
      (( $# >= 2 )) || {
        usage >&2
        exit 2
      }
      VISION_UDID=$2
      shift
      ;;
    --allow-user-simulator)
      ALLOW_USER_SIMULATOR=1
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ -z "$VISION_UDID" && -n "${PEONPAD_VISION_SIMULATOR_UDID:-}" ]]; then
  VISION_UDID=$PEONPAD_VISION_SIMULATOR_UDID
fi
if [[ "${PEONPAD_VISIONOS_ALLOW_USER_SIMULATOR:-0}" == 1 ]]; then
  ALLOW_USER_SIMULATOR=1
fi
if [[ -n "$VISION_UDID" && $ALLOW_USER_SIMULATOR -ne 1 ]]; then
  print -u2 "a user-selected simulator requires --allow-user-simulator"
  exit 2
fi
if [[ -z "$VISION_UDID" && $ALLOW_USER_SIMULATOR -eq 1 ]]; then
  print -u2 "--allow-user-simulator requires --simulator-udid"
  exit 2
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

SIMULATOR_STATE=""
SIMULATOR_CREATED=0
APP_LAUNCHED=0
typeset -a TARGET_ARGS
TARGET_ARGS=()

finish_simulator() {
  local exit_code=$?
  local cleanup_failed=0
  trap - EXIT INT TERM
  set +e
  if (( APP_LAUNCHED )); then
    "$SCRIPT_DIR/visionos-simulator.sh" terminate --udid "$VISION_UDID" \
      --bundle org.peonpad.ios "${TARGET_ARGS[@]}" \
      >/dev/null 2>&1 || cleanup_failed=1
  fi
  if (( SIMULATOR_CREATED )); then
    "$SCRIPT_DIR/visionos-simulator.sh" cleanup \
      --state "$SIMULATOR_STATE" >/dev/null 2>&1 || cleanup_failed=1
  fi
  (( exit_code != 0 || cleanup_failed == 0 )) || exit_code=1
  exit "$exit_code"
}
trap finish_simulator EXIT
trap 'exit 130' INT TERM

if [[ -z "$VISION_UDID" ]]; then
  SIMULATOR_STATE=$("$SCRIPT_DIR/visionos-simulator.sh" create \
    --label ipad-compat --owner-pid $$)
  SIMULATOR_CREATED=1
  DETAILS=$("$SCRIPT_DIR/visionos-simulator.sh" details \
    --state "$SIMULATOR_STATE")
  VISION_UDID=${DETAILS%%$'\t'*}
  TARGET_ARGS=(--state "$SIMULATOR_STATE")
else
  TARGET_ARGS=(--allow-user-simulator)
  "$SCRIPT_DIR/visionos-simulator.sh" assert --udid "$VISION_UDID" \
    "${TARGET_ARGS[@]}"
fi

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
  -DPEONPAD_IOS_CONTROL_DOCK=ON \
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
  "$SCRIPT_DIR/visionos-simulator.sh" boot --udid "$VISION_UDID" \
    "${TARGET_ARGS[@]}"
  "$SCRIPT_DIR/visionos-simulator.sh" install --udid "$VISION_UDID" \
    --app "$APP" "${TARGET_ARGS[@]}"
  "$SCRIPT_DIR/visionos-simulator.sh" launch --udid "$VISION_UDID" \
    --bundle org.peonpad.ios "${TARGET_ARGS[@]}"
  APP_LAUNCHED=1
  print "  launch:       requested successfully"
fi

print
print "Simulator success does not satisfy Vision Pro hardware acceptance."
