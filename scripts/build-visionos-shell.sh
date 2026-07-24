#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}

usage() {
  cat <<'EOF'
Usage: ./scripts/build-visionos-shell.sh <xrsimulator|xros>
  [--launch] [--screenshot PATH] [--child-env NAME=VALUE]
  [--simulator-udid UDID --allow-user-simulator]

Builds the complete native visionOS SDL3 smoke-shell configuration. Simulator
automation creates a disposable PeonPad-owned Vision Pro by default. A user
simulator requires an explicit UDID plus --allow-user-simulator. Automation
never foregrounds Simulator. This is not gameplay.
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
VISION_UDID=""
ALLOW_USER_SIMULATOR=0
typeset -a CHILD_ENV
CHILD_ENV=()
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
    --child-env)
      (( $# >= 2 )) || {
        usage >&2
        exit 2
      }
      CHILD_ENV+=("$2")
      shift
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

CMAKE_VERSION=$(cmake --version | awk 'NR == 1 {print $3}')
CMAKE_MAJOR=${CMAKE_VERSION%%.*}
CMAKE_REMAINDER=${CMAKE_VERSION#*.}
CMAKE_MINOR=${CMAKE_REMAINDER%%.*}
if [[ "$CMAKE_MAJOR" != <-> || "$CMAKE_MINOR" != <-> ]] \
    || (( CMAKE_MAJOR < 3 || (CMAKE_MAJOR == 3 && CMAKE_MINOR < 28) )); then
  print -u2 "native visionOS builds require CMake 3.28 or newer"
  print -u2 "CMAKE_SYSTEM_NAME=visionOS is unavailable in CMake ${CMAKE_VERSION:-unknown}"
  exit 1
fi

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
    "$SCRIPT_DIR/visionos-simulator.sh" terminate \
      --udid "$VISION_UDID" --bundle org.peonpad.visionos \
      "${TARGET_ARGS[@]}" >/dev/null 2>&1 || cleanup_failed=1
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
    --label smoke-shell --owner-pid $$)
  SIMULATOR_CREATED=1
  DETAILS=$("$SCRIPT_DIR/visionos-simulator.sh" details \
    --state "$SIMULATOR_STATE")
  VISION_UDID=${DETAILS%%$'\t'*}
  TARGET_ARGS=(--state "$SIMULATOR_STATE")
else
  TARGET_ARGS=(--allow-user-simulator)
  "$SCRIPT_DIR/visionos-simulator.sh" boot --udid "$VISION_UDID" \
    "${TARGET_ARGS[@]}"
fi
"$SCRIPT_DIR/visionos-simulator.sh" install --udid "$VISION_UDID" \
  --app "$APP" "${TARGET_ARGS[@]}"
typeset -a LAUNCH_ARGS
LAUNCH_ARGS=(--udid "$VISION_UDID" --bundle org.peonpad.visionos)
for assignment in "${CHILD_ENV[@]}"; do
  LAUNCH_ARGS+=(--env "$assignment")
done
LAUNCH_RESULT=$("$SCRIPT_DIR/visionos-simulator.sh" launch \
  "${LAUNCH_ARGS[@]}" "${TARGET_ARGS[@]}")
APP_LAUNCHED=1
print "$LAUNCH_RESULT"
PID=$(awk -F ': ' '$1 == "org.peonpad.visionos" {print $2}' \
  <<< "$LAUNCH_RESULT")
[[ "$PID" == <-> ]] || {
  print -u2 "simctl did not report the smoke-shell process identifier"
  exit 1
}
sleep 3
xcrun simctl spawn "$VISION_UDID" launchctl procinfo "$PID" >/dev/null
CONTAINER=$("$SCRIPT_DIR/visionos-simulator.sh" container \
  --udid "$VISION_UDID" --bundle org.peonpad.visionos --kind app \
  "${TARGET_ARGS[@]}")
[[ -d "$CONTAINER" ]] || {
  print -u2 "installed visionOS smoke app container is unavailable"
  exit 1
}

if [[ -n "$SCREENSHOT" ]]; then
  "$SCRIPT_DIR/visionos-simulator.sh" screenshot \
    --udid "$VISION_UDID" --output "$SCREENSHOT" "${TARGET_ARGS[@]}"
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
