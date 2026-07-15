#!/bin/zsh

set -eu
unsetopt BG_NICE

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
BINARY=${PEONPAD_MACOS_BINARY:-$ROOT_DIR/build/macos/stratagus}
SMOKE_SECONDS=${PEONPAD_SMOKE_SECONDS:-5}
RUNTIME_ROOT=${PEONPAD_RUNTIME_ROOT:-$ROOT_DIR/runtime/macos-smoke}
MODE=public

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--maintainer" ]]; }; then
  print -u2 "Usage: ./scripts/smoke-macos.sh [--maintainer]"
  exit 2
fi
if (( $# == 1 )); then
  MODE=maintainer
fi

[[ -x "$BINARY" ]] || {
  print -u2 "PeonPad-built executable is missing: $BINARY"
  exit 1
}

START_DIGEST=""
if [[ "$MODE" == maintainer ]]; then
  START_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
  EXPECTED_DIGEST=$(awk -F ' *= *' \
    '$1 == "tree_sha256" {gsub(/"/, "", $2); print $2; exit}' \
    "$ROOT_DIR/config/inputs.lock")
  [[ "$START_DIGEST" == "$EXPECTED_DIGEST" ]] || {
    print -u2 "ref/ does not match config/inputs.lock; refusing smoke test"
    exit 1
  }
fi

smoke_profile() {
  local profile=$1
  local data_path=$2
  local profile_root="$RUNTIME_ROOT/$profile"
  local user_path="$profile_root/user"
  local log_path="$profile_root/smoke.log"
  local pid=""

  mkdir -p "$user_path"
  env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    "$BINARY" -d "$data_path" -u "$user_path" -g -r -W \
    > "$log_path" 2>&1 &
  pid=$!

  local ticks=$(( SMOKE_SECONDS * 10 ))
  local tick
  for (( tick = 0; tick < ticks; tick++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      print -u2 "$profile exited before reaching a stable main loop"
      tail -80 "$log_path" >&2
      return 1
    fi
    sleep 0.1
  done

  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if grep -Eq 'Lua error|Error in Lua|stratagus.lua.*(failed|not found)' \
      "$log_path"; then
    print -u2 "$profile reported a configuration-script failure"
    tail -80 "$log_path" >&2
    return 1
  fi

  if grep -Eq "LoadMusic: Can't load|PlayMusic: Could not play" \
      "$log_path"; then
    print -u2 "$profile reported a music decoding or playback failure"
    tail -80 "$log_path" >&2
    return 1
  fi

  if [[ "$profile" == "wc2" ]] &&
      ! grep -Eq '^Supported music decoders:.*(DRFLAC|FLAC)' "$log_path"; then
    print -u2 "wc2 requires FLAC music support for extracted Ogg/FLAC tracks"
    tail -80 "$log_path" >&2
    return 1
  fi

  print "PASS  $profile content reached a stable main loop"
  print "      log: $log_path"
}

if [[ "$MODE" == maintainer ]]; then
  smoke_profile wc2 "$ROOT_DIR/ref/data.Wargus"
  smoke_profile aleona "$ROOT_DIR/assets/aleonas-tales/source"

  END_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
  [[ "$END_DIGEST" == "$START_DIGEST" ]] || {
    print -u2 "FATAL: ref/ changed during macOS smoke tests"
    exit 70
  }
  print "PASS  ref/ remained byte-for-byte unchanged"
else
  smoke_profile wc2 "${PEONPAD_WC2_DATA_DIR:-$ROOT_DIR/data.Wargus}"
fi
