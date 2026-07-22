#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}

usage() {
  cat <<'EOF'
Usage: ./scripts/build-visionos-tabletop.sh <xrsimulator|xros> [--launch] [--screenshot PATH]

Builds the native visionOS tabletop foundation app: a self-contained
SwiftUI + RealityKit executable compiled directly with swiftc (no Xcode
project, no CMake). This is entirely separate from the SDL3 smoke shell
built by build-visionos-shell.sh -- distinct bundle id, distinct executable,
distinct app bundle -- and from the Designed-for-iPad Warcraft II app.
--launch and --screenshot are supported only for xrsimulator. There is no
gameplay here: a procedural placeable board plus test unit billboards only.
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# < 1 )); then
  usage >&2
  exit 2
fi

TARGET=$1
shift
LAUNCH=0
SCREENSHOT=""
while (( $# > 0 )); do
  case "$1" in
    --launch)
      LAUNCH=1
      ;;
    --screenshot)
      (( $# >= 2 )) || {
        usage >&2
        exit 2
      }
      SCREENSHOT=${2:A}
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

case "$TARGET" in
  xrsimulator)
    SWIFT_TARGET_TRIPLE="arm64-apple-xros2.0-simulator"
    SUPPORTED_PLATFORM=XRSimulator
    ;;
  xros)
    SWIFT_TARGET_TRIPLE="arm64-apple-xros2.0"
    SUPPORTED_PLATFORM=XROS
    if (( LAUNCH )) || [[ -n "$SCREENSHOT" ]]; then
      print -u2 "simulator launch/evidence options cannot target xros"
      exit 2
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ -n "$SCREENSHOT" && $LAUNCH -eq 0 ]]; then
  print -u2 "--screenshot requires --launch"
  exit 2
fi
if [[ -n "$SCREENSHOT" ]]; then
  case "$SCREENSHOT/" in
    "$ROOT_DIR/"*)
      print -u2 "tabletop evidence must remain outside the repository"
      exit 1
      ;;
  esac
fi

BUNDLE_IDENTIFIER=${PEONPAD_TABLETOP_BUNDLE_IDENTIFIER:-org.peonpad.visionos.tabletop}
EXECUTABLE_NAME=PeonPadTabletop
APP_NAME="$EXECUTABLE_NAME.app"

BUILD_DIR=${PEONPAD_VISIONOS_BUILD_DIR:-$ROOT_DIR/build/visionos-tabletop-$TARGET}
BUILD_DIR=${BUILD_DIR:A}
case "$BUILD_DIR/" in
  "$ROOT_DIR/build/"*) ;;
  *)
    print -u2 "visionOS tabletop build directory must be inside $ROOT_DIR/build"
    exit 1
    ;;
esac

SDK_PATH=$(xcrun --sdk "$TARGET" --show-sdk-path) || {
  print -u2 "$TARGET SDK is unavailable"
  exit 1
}

TABLETOP_SRC_DIR="$ROOT_DIR/platform/apple/visionos/tabletop"
SOURCES=(
  "$TABLETOP_SRC_DIR/TabletopGestureState.swift"
  "$TABLETOP_SRC_DIR/TabletopSceneBuilder.swift"
  "$TABLETOP_SRC_DIR/TabletopPaletteView.swift"
  "$TABLETOP_SRC_DIR/TabletopBoardView.swift"
  "$TABLETOP_SRC_DIR/TabletopApp.swift"
)
for source in "${SOURCES[@]}"; do
  [[ -f "$source" ]] || {
    print -u2 "missing tabletop source file: $source"
    exit 1
  }
done

cmake -E remove_directory "$BUILD_DIR"
cmake -E make_directory "$BUILD_DIR"

APP="$BUILD_DIR/$APP_NAME"
cmake -E make_directory "$APP"

xcrun -sdk "$TARGET" swiftc \
  -target "$SWIFT_TARGET_TRIPLE" \
  -sdk "$SDK_PATH" \
  -parse-as-library \
  -O \
  -emit-executable \
  "${SOURCES[@]}" \
  -o "$APP/$EXECUTABLE_NAME"

sed \
  -e "s/@PEONPAD_TABLETOP_BUNDLE_IDENTIFIER@/$BUNDLE_IDENTIFIER/g" \
  -e "s/@PEONPAD_VISIONOS_SUPPORTED_PLATFORM@/$SUPPORTED_PLATFORM/g" \
  "$TABLETOP_SRC_DIR/Info.plist.in" > "$APP/Info.plist"
plutil -lint "$APP/Info.plist" >/dev/null

"$ROOT_DIR/platform/apple/visionos/compile-bundle-assets.sh" \
  "$TARGET" \
  cmake \
  "$APP" \
  "$ROOT_DIR/platform/apple/visionos/PeonPadAssets.xcassets" \
  "$ROOT_DIR/platform/apple/ios/PeonPadAssets.xcassets/AppIcon.appiconset/PeonPadIcon.png" \
  "$BUILD_DIR/tabletop-assets"

if [[ "$TARGET" == xrsimulator ]]; then
  codesign --force --sign - --timestamp=none "$APP"
  codesign --verify --deep --strict "$APP"
fi

"$SCRIPT_DIR/verify-tabletop-bundle.sh" "$TARGET" "$APP"

print
print "PeonPad native visionOS tabletop app built:"
print "  app:       $APP"
print "  target:    arm64 $TARGET, visionOS 2.0+"
print "  payload:   procedural placeable board + test unit billboards; no gameplay, no proprietary data"

if [[ "$TARGET" == xros ]]; then
  print "  signing:   unsigned"
  print
  print "DEVICE GATE: sign this bundle locally (ad-hoc/dev certificate) and"
  print "install it with your own provisioning before running on hardware."
  exit 0
fi

if (( ! LAUNCH )); then
  print "  launch:    not requested"
  exit 0
fi

VISION_UDID=$("$SCRIPT_DIR/find-vision-pro-simulator.sh")
STATE=$(xcrun simctl list devices available | awk -v id="$VISION_UDID" '
  index($0, "(" id ")") {
    if ($0 ~ /\(Booted\)/) print "Booted"
    else if ($0 ~ /\(Shutdown\)/) print "Shutdown"
    else print "Unknown"
    exit
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
LAUNCH_RESULT=$(xcrun simctl launch --terminate-running-process \
  "$VISION_UDID" "$BUNDLE_IDENTIFIER")
print "$LAUNCH_RESULT"
PID=$(awk -F ': ' -v id="$BUNDLE_IDENTIFIER" '$1 == id {print $2}' \
  <<< "$LAUNCH_RESULT")
[[ "$PID" == <-> ]] || {
  print -u2 "simctl did not report the tabletop-app process identifier"
  exit 1
}
sleep 5
xcrun simctl spawn "$VISION_UDID" launchctl procinfo "$PID" >/dev/null
CONTAINER=$(xcrun simctl get_app_container \
  "$VISION_UDID" "$BUNDLE_IDENTIFIER" app)
[[ -d "$CONTAINER" ]] || {
  print -u2 "installed visionOS tabletop app container is unavailable"
  exit 1
}

if [[ -n "$SCREENSHOT" ]]; then
  xcrun simctl io "$VISION_UDID" screenshot "$SCREENSHOT"
  [[ -s "$SCREENSHOT" ]] || {
    print -u2 "simulator screenshot was not captured"
    exit 1
  }
fi

RUNTIME=$(xcrun simctl list devices available | awk -v id="$VISION_UDID" '
  /^-- visionOS / {runtime = substr($0, 4, length($0) - 6)}
  index($0, "(" id ")") {print runtime; exit}
')
print "  simulator: Apple Vision Pro / $RUNTIME / $VISION_UDID"
print "  launch:    resident after 5 seconds (pid $PID)"
if [[ -n "$SCREENSHOT" ]]; then
  print "  evidence:  $SCREENSHOT (local, outside repository)"
fi
