#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
STAGED_DIR="$ROOT_DIR/build/visionos-wargus-data"
BUNDLE_IDENTIFIER=${PEONPAD_VISIONOS_BUNDLE_IDENTIFIER:-org.peonpad.visionos}
VISION_UDID=""
SIMULATOR_STATE=""
ALLOW_USER_SIMULATOR=0
PRINT_PATHS=0

usage() {
  cat <<'EOF'
Usage: ./scripts/inject-visionos-wargus-data.sh
  (--state PATH | --udid UDID --allow-user-simulator) [--print-paths]

Injects already-staged private Wargus game data from build/visionos-wargus-data/
into the visionOS simulator app container for the PeonPad native shell. The app
must already be installed in the simulator.

The staged read-only game data is copied to:
  <data-container>/Documents/wargus-data/

The writable user/config/save/log path (created at runtime by the engine via
SDL_GetPrefPath) will be inside:
  <data-container>/Library/Application Support/<bundle-id>/

Options:
  --state PATH       Ownership metadata from visionos-simulator.sh create.
  --udid UDID        Explicit user-selected Vision Pro simulator.
  --allow-user-simulator
                    Required opt-in with a user-selected --udid.
  --print-paths     Print the deterministic data and user paths and exit without
                    performing injection. Useful for engine/CMake integration.

Environment:
  PEONPAD_VISIONOS_BUNDLE_IDENTIFIER  Bundle id (default: org.peonpad.visionos)

Prerequisites:
  1. Stage game data:  ./scripts/stage-visionos-wargus-data.sh
  2. Build the app:    ./scripts/build-visionos-shell.sh xrsimulator
  3. Install the app on an explicit owned simulator with
     scripts/visionos-simulator.sh.

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
    --state)
      (( $# >= 2 )) || {
        usage >&2
        exit 2
      }
      SIMULATOR_STATE=${2:A}
      shift 2
      ;;
    --udid)
      (( $# >= 2 )) || {
        usage >&2
        exit 2
      }
      VISION_UDID=$2
      shift 2
      ;;
    --allow-user-simulator)
      ALLOW_USER_SIMULATOR=1
      shift
      ;;
    *)
      print -u2 "unexpected argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

typeset -a TARGET_ARGS
TARGET_ARGS=()
if [[ -n "$SIMULATOR_STATE" ]]; then
  (( ! ALLOW_USER_SIMULATOR )) || {
    print -u2 "--allow-user-simulator cannot be combined with --state"
    exit 2
  }
  DETAILS=$("$SCRIPT_DIR/visionos-simulator.sh" details \
    --state "$SIMULATOR_STATE")
  VISION_UDID=${DETAILS%%$'\t'*}
  TARGET_ARGS=(--state "$SIMULATOR_STATE")
elif [[ -n "$VISION_UDID" && $ALLOW_USER_SIMULATOR -eq 1 ]]; then
  TARGET_ARGS=(--allow-user-simulator)
else
  print -u2 "injection requires owned --state or explicit --udid with --allow-user-simulator"
  exit 2
fi
"$SCRIPT_DIR/visionos-simulator.sh" assert \
  --udid "$VISION_UDID" "${TARGET_ARGS[@]}"

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
  DATA_CONTAINER=$("$SCRIPT_DIR/visionos-simulator.sh" container \
    --udid "$VISION_UDID" --bundle "$BUNDLE_IDENTIFIER" --kind data \
    "${TARGET_ARGS[@]}" 2>/dev/null || true)
  if [[ -d "$DATA_CONTAINER" ]]; then
    print "game_data=$DATA_CONTAINER/Documents/wargus-data"
    print "user=$DATA_CONTAINER/Library/Application Support/$BUNDLE_IDENTIFIER/user"
  else
    print "game_data=(app not yet installed in simulator)"
    print "user=(app not yet installed in simulator)"
  fi
  exit 0
fi

# ── Resolve the simulator data container ──────────────────────────────────────

DATA_CONTAINER=$("$SCRIPT_DIR/visionos-simulator.sh" container \
  --udid "$VISION_UDID" --bundle "$BUNDLE_IDENTIFIER" --kind data \
  "${TARGET_ARGS[@]}" 2>/dev/null || true)
[[ -d "$DATA_CONTAINER" ]] || {
  print -u2 "visionOS app data container unavailable for $BUNDLE_IDENTIFIER"
  print -u2 "Install the app first, then run this script."
  print -u2 ""
  print -u2 "To build and install:"
  print -u2 "  ./scripts/visionos-simulator.sh install --state <state> --udid <udid> --app <app>"
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
