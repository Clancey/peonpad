#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}

usage() {
  cat <<'EOF'
Usage: ./scripts/build-visionos-shell.sh <xrsimulator|xros> [--launch] [--screenshot PATH]

Builds the complete native visionOS SDL3 smoke-shell configuration. --launch
and --screenshot are supported only for xrsimulator. This is not gameplay.
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
    TOOLCHAIN="$ROOT_DIR/cmake/toolchains/xros-simulator-arm64.cmake"
    ;;
  xros)
    TOOLCHAIN="$ROOT_DIR/cmake/toolchains/xros-arm64.cmake"
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
      print -u2 "smoke evidence must remain outside the repository"
      exit 1
      ;;
  esac
fi

BUILD_DIR=${PEONPAD_VISIONOS_BUILD_DIR:-$ROOT_DIR/build/visionos-$TARGET}
BUILD_DIR=${BUILD_DIR:A}
case "$BUILD_DIR/" in
  "$ROOT_DIR/build/"*) ;;
  *)
    print -u2 "visionOS build directory must be inside $ROOT_DIR/build"
    exit 1
    ;;
esac

"$SCRIPT_DIR/verify-sdl3-sources.sh"
xcrun --sdk "$TARGET" --show-sdk-path >/dev/null || {
  print -u2 "$TARGET SDK is unavailable"
  exit 1
}

cmake -E remove_directory "$BUILD_DIR"
cmake --fresh -S "$ROOT_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPEONPAD_ENABLE_ENGINE=OFF \
  -DPEONPAD_ENABLE_SDL3=ON \
  -DBUILD_TESTING=OFF

# Deliberately build the complete all target, including the toolchain probe,
# SDL3-family libraries, input adapter, native bridge, and application bundle.
cmake --build "$BUILD_DIR" --parallel

APP="$BUILD_DIR/PeonPadVisionShell.app"
[[ -d "$APP" ]] || {
  print -u2 "missing native visionOS smoke app: $APP"
  exit 1
}
cmp -s "$BUILD_DIR/_deps/peonpad_sdl3-src/test/icon.png" \
  "$APP/icon.png"
cmp -s "$BUILD_DIR/_deps/peonpad_sdl3_mixer-src/examples/spring.wav" \
  "$APP/spring.wav"

if [[ "$TARGET" == xrsimulator ]]; then
  codesign --force --sign - --timestamp=none "$APP"
  codesign --verify --deep --strict "$APP"
fi
"$SCRIPT_DIR/verify-visionos-bundle.sh" "$TARGET" "$APP"

print
print "PeonPad native visionOS smoke shell built:"
print "  app:       $APP"
print "  target:    arm64 $TARGET, visionOS 2.0+"
print "  payload:   public SDL3 shell smoke; no playable gameplay"

if [[ "$TARGET" == xros ]]; then
  print "  signing:   unsigned"
  print
  print "DEVICE GATE: generate an Xcode build with"
  print "PEONPAD_VISIONOS_ENABLE_SIGNING=ON and your local DEVELOPMENT_TEAM."
  print "Then verify/install it with scripts/install-visionos-device.sh."
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
  "$VISION_UDID" org.peonpad.visionos)
print "$LAUNCH_RESULT"
PID=$(awk -F ': ' '$1 == "org.peonpad.visionos" {print $2}' \
  <<< "$LAUNCH_RESULT")
[[ "$PID" == <-> ]] || {
  print -u2 "simctl did not report the smoke-shell process identifier"
  exit 1
}
sleep 3
xcrun simctl spawn "$VISION_UDID" launchctl procinfo "$PID" >/dev/null
CONTAINER=$(xcrun simctl get_app_container \
  "$VISION_UDID" org.peonpad.visionos app)
[[ -d "$CONTAINER" ]] || {
  print -u2 "installed visionOS smoke app container is unavailable"
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
print "  launch:    resident after 3 seconds (pid $PID)"
if [[ -n "$SCREENSHOT" ]]; then
  print "  evidence:  $SCREENSHOT (local, outside repository)"
fi
