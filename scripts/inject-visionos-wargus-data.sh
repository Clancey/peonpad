#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
STAGED_DIR="$ROOT_DIR/build/visionos-wargus-data"
BUNDLE_IDENTIFIER=${PEONPAD_VISIONOS_BUNDLE_IDENTIFIER:-org.peonpad.visionos}
VISION_UDID=""
PRINT_PATHS=0

usage() {
  cat <<'EOF'
Usage: ./scripts/inject-visionos-wargus-data.sh [--print-paths]

Injects already-staged private Wargus game data from build/visionos-wargus-data/
into the visionOS simulator app container for the PeonPad native shell. The app
must already be installed in the simulator.

The staged read-only game data is copied to:
  <data-container>/Documents/wargus-data/

The writable user/config/save/log path (created at runtime by the engine via
SDL_GetPrefPath) will be inside:
  <data-container>/Library/Application Support/<bundle-id>/

Options:
  --print-paths     Print the deterministic data and user paths and exit without
                    performing injection. Useful for engine/CMake integration.

Environment:
  PEONPAD_VISION_SIMULATOR_UDID    Override the simulator to target; must be a
                                   visionOS Apple Vision Pro simulator UDID.
  PEONPAD_VISIONOS_BUNDLE_IDENTIFIER  Bundle id (default: org.peonpad.visionos)

Prerequisites:
  1. Stage game data:  ./scripts/stage-visionos-wargus-data.sh
  2. Build the app:    ./scripts/build-visionos-shell.sh xrsimulator
  3. Install the app:  xcrun simctl install <UDID> <app>
     or build with --launch:  ./scripts/build-visionos-shell.sh xrsimulator --launch

After injection the engine can read game data from:
  Documents/wargus-data/

Writable state (saves, config, logs) goes to:
  Library/Application Support/<bundle-id>/user/  (engine-managed via SDL_GetPrefPath)
EOF
}

if (( $# == 1 )) && [[ "$1" == (--help|-h) ]]; then
  usage
  exit 0
fi

while (( $# > 0 )); do
  case "$1" in
    --print-paths)
      PRINT_PATHS=1
      shift
      ;;
    *)
      print -u2 "unexpected argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

# ── Validate staged source (before any xcrun calls) ───────────────────────────

[[ -d "$STAGED_DIR" ]] || {
  print -u2 "staged game data not found: build/visionos-wargus-data"
  print -u2 "Stage owned Wargus data first:"
  print -u2 "  PEONPAD_WARGUS_DATA_DIR=/path/to/data.Wargus \\"
  print -u2 "    ./scripts/stage-visionos-wargus-data.sh"
  exit 1
}
[[ -s "$STAGED_DIR/scripts/stratagus.lua" ]] || {
  print -u2 "staged data appears incomplete: missing scripts/stratagus.lua"
  print -u2 "Re-run: ./scripts/stage-visionos-wargus-data.sh"
  exit 1
}

if (( PRINT_PATHS )); then
  # Resolve the simulator to get the actual container paths.
  VISION_UDID=$("$SCRIPT_DIR/find-vision-pro-simulator.sh")
  [[ -n "$VISION_UDID" ]] || {
    print -u2 "no Apple Vision Pro simulator found"
    exit 1
  }
  DATA_CONTAINER=$(xcrun simctl get_app_container \
    "$VISION_UDID" "$BUNDLE_IDENTIFIER" data 2>/dev/null || true)
  if [[ -d "$DATA_CONTAINER" ]]; then
    print "game_data=$DATA_CONTAINER/Documents/wargus-data"
    print "user=$DATA_CONTAINER/Library/Application Support/$BUNDLE_IDENTIFIER/user"
  else
    print "game_data=(app not yet installed in simulator)"
    print "user=(app not yet installed in simulator)"
  fi
  exit 0
fi

# ── Locate the simulator ───────────────────────────────────────────────────────

VISION_UDID=$("$SCRIPT_DIR/find-vision-pro-simulator.sh")
[[ -n "$VISION_UDID" ]] || {
  print -u2 "no Apple Vision Pro simulator found"
  exit 1
}

# ── Resolve the simulator data container ──────────────────────────────────────

DATA_CONTAINER=$(xcrun simctl get_app_container \
  "$VISION_UDID" "$BUNDLE_IDENTIFIER" data 2>/dev/null || true)
[[ -d "$DATA_CONTAINER" ]] || {
  print -u2 "visionOS app data container unavailable for $BUNDLE_IDENTIFIER"
  print -u2 "Install the app first, then run this script."
  print -u2 ""
  print -u2 "To build and install:"
  print -u2 "  ./scripts/build-visionos-shell.sh xrsimulator --launch"
  exit 1
}

GAME_DATA_PATH="$DATA_CONTAINER/Documents/wargus-data"
USER_PATH="$DATA_CONTAINER/Library/Application Support/$BUNDLE_IDENTIFIER/user"

# ── Inject into the app container ─────────────────────────────────────────────

# The destination lives inside the simulator container — never inside the
# repository — so no game assets can reach a tracked source location.
mkdir -p "$GAME_DATA_PATH"
rsync -a --delete --delete-excluded \
  --exclude .DS_Store \
  "$STAGED_DIR/" "$GAME_DATA_PATH/"

# Pre-create the writable user directory so the engine finds it immediately.
mkdir -p "$USER_PATH"

print "Injected Wargus game data into visionOS simulator container:"
print "  simulator:  $VISION_UDID"
print "  app:        $BUNDLE_IDENTIFIER"
print "  game data:  $GAME_DATA_PATH  (read-only by convention)"
print "  user data:  $USER_PATH  (writable; engine-managed)"
print ""
print "The engine receives the data path via -d and user path via -u."
print "SDL_GetPrefPath will also resolve under the user data directory."
