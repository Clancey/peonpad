#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/build-visionos-tabletop.sh xrsimulator [--launch] [--screenshot PATH]
  ./scripts/build-visionos-tabletop.sh xros --unsigned
  ./scripts/build-visionos-tabletop.sh xros --team TEAM_ID [--bundle-id IDENTIFIER]

The device signing route uses the local Xcode account and allows provisioning
updates. It never stores credentials, team IDs, or profiles in the repository.
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
UNSIGNED=0
TEAM=""
BUNDLE_ID=org.peonpad.tabletop
while (( $# > 0 )); do
  case "$1" in
    --launch) LAUNCH=1 ;;
    --screenshot)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      SCREENSHOT=${2:A}
      shift
      ;;
    --unsigned) UNSIGNED=1 ;;
    --team)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      TEAM=$2
      shift
      ;;
    --bundle-id)
      (( $# >= 2 )) || { usage >&2; exit 2; }
      BUNDLE_ID=$2
      shift
      ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$TARGET" in
  xrsimulator)
    TOOLCHAIN="$ROOT_DIR/cmake/toolchains/xros-simulator-arm64.cmake"
    [[ -z "$TEAM" && $UNSIGNED -eq 0 ]] || {
      print -u2 "signing options are valid only for xros"
      exit 2
    }
    ;;
  xros)
    TOOLCHAIN="$ROOT_DIR/cmake/toolchains/xros-arm64.cmake"
    (( ! LAUNCH )) && [[ -z "$SCREENSHOT" ]] || {
      print -u2 "simulator launch/evidence options cannot target xros"
      exit 2
    }
    if [[ -n "$TEAM" && $UNSIGNED -eq 1 ]] || [[ -z "$TEAM" && $UNSIGNED -eq 0 ]]; then
      print -u2 "xros requires exactly one of --team TEAM_ID or --unsigned"
      exit 2
    fi
    ;;
  *) usage >&2; exit 2 ;;
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

BUILD_DIR=${PEONPAD_TABLETOP_BUILD_DIR:-$ROOT_DIR/build/visionos-tabletop-$TARGET}
BUILD_DIR=${BUILD_DIR:A}
case "$BUILD_DIR/" in
  "$ROOT_DIR/build/"*) ;;
  *)
    print -u2 "tabletop build directory must be inside $ROOT_DIR/build"
    exit 1
    ;;
esac

"$SCRIPT_DIR/test-tabletop-gestures.sh"
xcrun --sdk "$TARGET" --show-sdk-path >/dev/null
cmake -E remove_directory "$BUILD_DIR"

SIGNING=OFF
[[ -z "$TEAM" ]] || SIGNING=ON
cmake -S "$ROOT_DIR" -B "$BUILD_DIR" -G Xcode \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DPEONPAD_ENABLE_ENGINE=OFF \
  -DPEONPAD_ENABLE_SDL3=OFF \
  -DPEONPAD_ENABLE_TABLETOP=ON \
  -DPEONPAD_VISIONOS_ENABLE_SIGNING="$SIGNING" \
  -DPEONPAD_TABLETOP_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  -DBUILD_TESTING=OFF

if [[ -n "$TEAM" ]]; then
  xcodebuild -project "$BUILD_DIR/PeonPad.xcodeproj" \
    -scheme peonpad_tabletop -configuration Release \
    -destination 'generic/platform=visionOS' \
    DEVELOPMENT_TEAM="$TEAM" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    -allowProvisioningUpdates build
else
  cmake --build "$BUILD_DIR" --config Release --target peonpad_tabletop
fi

APP=$(find "$BUILD_DIR" -type d -name PeonPadTabletop.app -print -quit)
[[ -n "$APP" && -d "$APP" ]] || {
  print -u2 "missing native visionOS tabletop app"
  exit 1
}

if [[ "$TARGET" == xrsimulator ]]; then
  codesign --force --sign - --timestamp=none "$APP"
  PEONPAD_TABLETOP_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    "$SCRIPT_DIR/verify-tabletop-bundle.sh" "$TARGET" "$APP"
elif [[ -n "$TEAM" ]]; then
  PEONPAD_TABLETOP_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    "$SCRIPT_DIR/verify-tabletop-bundle.sh" "$TARGET" "$APP" --signed
else
  PEONPAD_TABLETOP_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    "$SCRIPT_DIR/verify-tabletop-bundle.sh" "$TARGET" "$APP"
fi

print
print "PeonPad native visionOS tabletop built:"
print "  app:       $APP"
print "  target:    arm64 $TARGET, visionOS 2.0+"
print "  payload:   procedural SwiftUI + RealityKit tabletop"

if [[ "$TARGET" == xros ]]; then
  [[ -z "$TEAM" ]] && print "  signing:   unsigned compile gate" \
    || print "  signing:   Xcode development signed"
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
  "$VISION_UDID" "$BUNDLE_ID")
print "$LAUNCH_RESULT"
PID=$(awk -F ': ' -v bundle="$BUNDLE_ID" '$1 == bundle {print $2}' \
  <<< "$LAUNCH_RESULT")
[[ "$PID" == <-> ]] || {
  print -u2 "simctl did not report the tabletop process identifier"
  exit 1
}
sleep 4
PROCINFO=$(xcrun simctl spawn "$VISION_UDID" launchctl procinfo "$PID" 2>&1)
[[ "$PROCINFO" != *"Could not get proc info"* ]] || {
  print -u2 "tabletop process exited before the residency check"
  print -u2 "$PROCINFO"
  exit 1
}

if [[ -n "$SCREENSHOT" ]]; then
  xcrun simctl io "$VISION_UDID" screenshot "$SCREENSHOT"
  [[ -s "$SCREENSHOT" ]] || {
    print -u2 "simulator screenshot was not captured"
    exit 1
  }
fi

print "  simulator: Apple Vision Pro / $VISION_UDID"
print "  launch:    resident after 4 seconds (pid $PID)"
[[ -z "$SCREENSHOT" ]] || \
  print "  evidence:  $SCREENSHOT (local, outside repository)"
