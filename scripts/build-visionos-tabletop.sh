#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}

usage() {
  cat <<'EOF'
Usage: ./scripts/build-visionos-tabletop.sh <xrsimulator|xros>
  [--launch] [--screenshot PATH] [--inject-wargus-data]
  [--child-env NAME=VALUE]
  [--simulator-udid UDID --allow-user-simulator]

Builds the native visionOS tabletop app: a SwiftUI + RealityKit executable
compiled directly with swiftc (no Xcode project) and linked against the real
Stratagus/Wargus SDL3 engine + the tabletop bridge, so it boots a live
scenario and renders it on the placeable 3D board. This is separate from the
SDL3 smoke shell built by build-visionos-shell.sh -- distinct bundle id,
executable, and app bundle -- and from the Designed-for-iPad Warcraft II app.
Simulator automation creates and cleans up a disposable PeonPad-owned Vision Pro
by default and never foregrounds Simulator. A user simulator requires an
explicit UDID plus --allow-user-simulator. --launch and --screenshot are
supported only for xrsimulator. The engine
static libraries are built on demand via build-visionos-engine-libs.sh. No
proprietary game data or art is bundled; the app reads staged data at runtime.
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
INJECT_WARGUS_DATA=0
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
    --inject-wargus-data)
      INJECT_WARGUS_DATA=1
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
if (( INJECT_WARGUS_DATA && ! LAUNCH )); then
  print -u2 "--inject-wargus-data requires --launch"
  exit 2
fi

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
  "$TABLETOP_SRC_DIR/TabletopBoardLayers.swift"
  "$TABLETOP_SRC_DIR/TabletopIndirectNavigation.swift"
  "$TABLETOP_SRC_DIR/TabletopGameplayState.swift"
  "$TABLETOP_SRC_DIR/TabletopTransport.swift"
  "$TABLETOP_SRC_DIR/TabletopGameplaySource.swift"
  "$TABLETOP_SRC_DIR/TabletopBoardReconciler.swift"
  "$TABLETOP_SRC_DIR/TabletopCommandHarness.swift"
  "$TABLETOP_SRC_DIR/TabletopSceneBuilder.swift"
  "$TABLETOP_SRC_DIR/TabletopActionPanel.swift"
  "$TABLETOP_SRC_DIR/TabletopActionPanelView.swift"
  "$TABLETOP_SRC_DIR/TabletopBoardView.swift"
  "$TABLETOP_SRC_DIR/TabletopApp.swift"
  "$TABLETOP_SRC_DIR/EngineTabletopModel.swift"
  "$TABLETOP_SRC_DIR/TabletopSnapshotConverter.swift"
  "$TABLETOP_SRC_DIR/EngineCommandEncoder.swift"
  "$TABLETOP_SRC_DIR/TabletopMapFit.swift"
  "$TABLETOP_SRC_DIR/WargusTabletopAssetResolver.swift"
  "$TABLETOP_SRC_DIR/TabletopAssetResolution.swift"
  "$TABLETOP_SRC_DIR/WargusTabletopMaterialProvider.swift"
  "$TABLETOP_SRC_DIR/EngineStartupPlan.swift"
  "$TABLETOP_SRC_DIR/EngineTabletopTransport.swift"
  "$TABLETOP_SRC_DIR/TabletopChunkGeometry.swift"
  "$TABLETOP_SRC_DIR/TabletopTerrainAtlasImage.swift"
  "$TABLETOP_SRC_DIR/TabletopChunkReadiness.swift"
  "$TABLETOP_SRC_DIR/TabletopFogMap.swift"
  "$TABLETOP_SRC_DIR/TabletopChunkBoard.swift"
)
for source in "${SOURCES[@]}"; do
  [[ -f "$source" ]] || {
    print -u2 "missing tabletop source file: $source"
    exit 1
  }
done

# ── Engine linkage ─────────────────────────────────────────────────────────
# The production tabletop app links the real Stratagus/Wargus engine + SDL3 so
# it can boot a live scenario and drive the board from published snapshots. The
# Objective-C++ engine host bridges Swift to the engine entry point and the
# bridge C ABI. Build the engine static libraries first (with the tabletop
# bridge compiled in) if they are not already present.
ENGINE_BUILD=${PEONPAD_VISIONOS_ENGINE_BUILD_DIR:-$ROOT_DIR/build/visionos-$TARGET-engine}
ENGINE_BUILD=${ENGINE_BUILD:A}
ENGINE_ARCHIVE="$ENGINE_BUILD/engine/libstratagus_lib.a"
if [[ ! -f "$ENGINE_ARCHIVE" ]]; then
  print "engine libraries not found; building them for $TARGET…"
  PEONPAD_VISIONOS_ENGINE_BUILD_DIR="$ENGINE_BUILD" \
    "$SCRIPT_DIR/build-visionos-engine-libs.sh" "$TARGET"
fi
[[ -f "$ENGINE_ARCHIVE" ]] || {
  print -u2 "engine archive missing after build: $ENGINE_ARCHIVE"
  exit 1
}

BRIDGE_DIR="$TABLETOP_SRC_DIR/bridge"
BRIDGE_HEADER="$BRIDGE_DIR/PeonPadTabletop-Bridging-Header.h"
ENGINE_HOST_SRC="$BRIDGE_DIR/PeonPadEngineHost.mm"
for f in "$BRIDGE_HEADER" "$ENGINE_HOST_SRC"; do
  [[ -f "$f" ]] || { print -u2 "missing bridge file: $f"; exit 1; }
done

# The full set of engine + SDL3 + vendored-media static libraries produced by
# build-visionos-engine-libs.sh. Order is not significant to the Apple linker.
ENGINE_LIBS=(
  "$ENGINE_BUILD/engine/libstratagus_lib.a"
  "$ENGINE_BUILD/engine/libguisan_lib.a"
  "$ENGINE_BUILD/libpeonpad_sdl3_input_adapter.a"
  "$ENGINE_BUILD/libpeonpad_sdl3_mixer_adapter.a"
  "$ENGINE_BUILD/_deps/peonpad_sdl3_image-build/libSDL3_image.a"
  "$ENGINE_BUILD/_deps/peonpad_sdl3_mixer-build/libSDL3_mixer.a"
  "$ENGINE_BUILD/_deps/peonpad_sdl3-build/libSDL3.a"
  "$ENGINE_BUILD/engine/lua/src/lua-build/liblua51.a"
  "$ENGINE_BUILD/engine/lua/src/lua-build/libtoluapp51.a"
  "$ENGINE_BUILD/engine/png/src/png-build/libpng16.a"
  "$ENGINE_BUILD/engine/jpeg/src/jpeg-build/libjpeg.a"
  "$ENGINE_BUILD/engine/lcms/src/lcms-build/liblcms.a"
  "$ENGINE_BUILD/engine/mng/src/mng-build/libmng.a"
  "$ENGINE_BUILD/engine/libtheora.a"
  "$ENGINE_BUILD/engine/vorbis/src/vorbis-build/lib/libvorbisfile.a"
  "$ENGINE_BUILD/engine/vorbis/src/vorbis-build/lib/libvorbisenc.a"
  "$ENGINE_BUILD/engine/vorbis/src/vorbis-build/lib/libvorbis.a"
  "$ENGINE_BUILD/engine/ogg/src/ogg-build/libogg.a"
  "$ENGINE_BUILD/engine/bzip2/src/bzip2-build/libbz2.a"
  "$ENGINE_BUILD/engine/zlib/src/zlib-build/libz.a"
)
for lib in "${ENGINE_LIBS[@]}"; do
  [[ -f "$lib" ]] || { print -u2 "missing engine library: $lib"; exit 1; }
done

ENGINE_FRAMEWORKS=(
  -framework Foundation -framework UIKit -framework Metal -framework QuartzCore
  -framework CoreGraphics -framework AVFoundation -framework AudioToolbox
  -framework CoreAudio -framework CoreMedia -framework CoreVideo
  -framework CoreMotion -framework GameController -framework CoreHaptics
  -framework ImageIO -framework Security -framework UniformTypeIdentifiers
)

cmake -E remove_directory "$BUILD_DIR"
cmake -E make_directory "$BUILD_DIR"

APP="$BUILD_DIR/$APP_NAME"
cmake -E make_directory "$APP"

# Compile the Objective-C++ engine host (boots the engine on a dedicated
# thread and drives the bridge C ABI) for the target.
ENGINE_HOST_OBJ="$BUILD_DIR/PeonPadEngineHost.o"
xcrun -sdk "$TARGET" clang++ \
  -target "$SWIFT_TARGET_TRIPLE" \
  -isysroot "$SDK_PATH" \
  -std=c++17 -fobjc-arc -O \
  -I "$ROOT_DIR/platform/bridge" \
  -I "$BRIDGE_DIR" \
  -c "$ENGINE_HOST_SRC" \
  -o "$ENGINE_HOST_OBJ"

# Compile the Swift app and link it against the engine host object, the engine
# + SDL3 static libraries, and the required system frameworks. The bridging
# header exposes the bridge C ABI and the engine host to Swift.
xcrun -sdk "$TARGET" swiftc \
  -target "$SWIFT_TARGET_TRIPLE" \
  -sdk "$SDK_PATH" \
  -parse-as-library \
  -O \
  -emit-executable \
  -import-objc-header "$BRIDGE_HEADER" \
  -I "$ROOT_DIR/platform/bridge" \
  -I "$BRIDGE_DIR" \
  "${SOURCES[@]}" \
  "$ENGINE_HOST_OBJ" \
  "${ENGINE_LIBS[@]}" \
  "${ENGINE_FRAMEWORKS[@]}" \
  -lc++ -liconv \
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
print "  payload:   live Stratagus/Wargus engine on the placeable board; reads staged data at runtime; no proprietary data or art bundled"

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
      --udid "$VISION_UDID" --bundle "$BUNDLE_IDENTIFIER" \
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
    --label tabletop --owner-pid $$)
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
if (( INJECT_WARGUS_DATA )); then
  PEONPAD_VISIONOS_BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" \
    "$SCRIPT_DIR/inject-visionos-wargus-data.sh" \
      --udid "$VISION_UDID" "${TARGET_ARGS[@]}"
fi
typeset -a LAUNCH_ARGS
LAUNCH_ARGS=(--udid "$VISION_UDID" --bundle "$BUNDLE_IDENTIFIER")
for assignment in "${CHILD_ENV[@]}"; do
  LAUNCH_ARGS+=(--env "$assignment")
done
LAUNCH_RESULT=$("$SCRIPT_DIR/visionos-simulator.sh" launch \
  "${LAUNCH_ARGS[@]}" "${TARGET_ARGS[@]}")
APP_LAUNCHED=1
print "$LAUNCH_RESULT"
PID=$(awk -F ': ' -v id="$BUNDLE_IDENTIFIER" '$1 == id {print $2}' \
  <<< "$LAUNCH_RESULT")
[[ "$PID" == <-> ]] || {
  print -u2 "simctl did not report the tabletop-app process identifier"
  exit 1
}
sleep 5
xcrun simctl spawn "$VISION_UDID" launchctl procinfo "$PID" >/dev/null
CONTAINER=$("$SCRIPT_DIR/visionos-simulator.sh" container \
  --udid "$VISION_UDID" --bundle "$BUNDLE_IDENTIFIER" --kind app \
  "${TARGET_ARGS[@]}")
[[ -d "$CONTAINER" ]] || {
  print -u2 "installed visionOS tabletop app container is unavailable"
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
print "  launch:    resident after 5 seconds (pid $PID)"
if [[ -n "$SCREENSHOT" ]]; then
  print "  evidence:  $SCREENSHOT (local, outside repository)"
fi
