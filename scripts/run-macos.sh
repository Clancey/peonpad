#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
BINARY="$ROOT_DIR/build/macos/stratagus"
PROFILE=wc2
DATA_PATH=""
EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./scripts/run-macos.sh [options] [-- Stratagus options]

Options:
  --binary PATH   PeonPad-built Stratagus executable
                  (default: build/macos/stratagus)
  --profile NAME  Isolated runtime profile: wc2 or aleona (default: wc2)
  --data PATH     Read-only game-data directory; defaults by profile
  -h, --help      Show this help

All preferences, saves, logs, HOME state, caches, and temporary files are
redirected to runtime/macos/NAME/. Binaries inside ref/ are rejected because
they cannot satisfy the PeonPad macOS baseline acceptance test.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --binary)
      (( $# >= 2 )) || { print -u2 "--binary requires a path"; exit 2; }
      BINARY=$2
      shift 2
      ;;
    --profile)
      (( $# >= 2 )) || { print -u2 "--profile requires a name"; exit 2; }
      PROFILE=$2
      shift 2
      ;;
    --data)
      (( $# >= 2 )) || { print -u2 "--data requires a path"; exit 2; }
      DATA_PATH=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS=("$@")
      break
      ;;
    *)
      print -u2 "unexpected argument: $1"
      usage >&2
      exit 2
      ;;
  esac
done

case "$PROFILE" in
  wc2)
    [[ -n "$DATA_PATH" ]] || DATA_PATH="$ROOT_DIR/data.Wargus"
    ;;
  aleona)
    [[ -n "$DATA_PATH" ]] || DATA_PATH="$ROOT_DIR/assets/aleonas-tales/source"
    ;;
  *)
    print -u2 "profile must be 'wc2' or 'aleona': $PROFILE"
    exit 2
    ;;
esac

[[ -x "$BINARY" ]] || {
  print -u2 "PeonPad-built executable is missing or not executable: $BINARY"
  exit 1
}
[[ -d "$DATA_PATH" ]] || {
  print -u2 "data directory is missing: $DATA_PATH"
  exit 1
}

BINARY=${BINARY:A}
DATA_PATH=${DATA_PATH:A}

case "$BINARY/" in
  "$ROOT_DIR/ref/"*)
    print -u2 "refusing reference executable; build PeonPad from source first"
    exit 1
    ;;
esac

REFERENCE_DIGEST=""
case "$DATA_PATH/" in
  "$ROOT_DIR/ref/"*)
    REFERENCE_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
    EXPECTED_DIGEST=$(awk -F ' *= *' \
      '$1 == "tree_sha256" {gsub(/"/, "", $2); print $2; exit}' \
      "$ROOT_DIR/config/inputs.lock")
    [[ "$REFERENCE_DIGEST" == "$EXPECTED_DIGEST" ]] || {
      print -u2 "ref/ does not match config/inputs.lock; refusing to launch"
      exit 1
    }
    ;;
esac

verify_reference_on_exit() {
  local exit_status=$?
  trap - EXIT
  if [[ -n "$REFERENCE_DIGEST" ]]; then
    local end_reference_digest
    end_reference_digest=$($SCRIPT_DIR/reference-digest.sh)
    if [[ "$end_reference_digest" != "$REFERENCE_DIGEST" ]]; then
      print -u2 "FATAL: ref/ changed during the gameplay run"
      exit 70
    fi
    print "Verified: ref/ remained byte-for-byte unchanged."
  fi
  exit "$exit_status"
}

trap verify_reference_on_exit EXIT

RUNTIME_BASE=${PEONPAD_RUNTIME_ROOT:-$ROOT_DIR/runtime/macos}
RUNTIME_ROOT="$RUNTIME_BASE/$PROFILE"
USER_PATH="$RUNTIME_ROOT/user"
HOME_PATH="$RUNTIME_ROOT/home"
CACHE_PATH="$RUNTIME_ROOT/cache"
TEMP_PATH="$RUNTIME_ROOT/tmp"
LOG_PATH="$RUNTIME_ROOT/logs"
mkdir -p "$USER_PATH" "$HOME_PATH" "$CACHE_PATH" "$TEMP_PATH" "$LOG_PATH"

RUN_LOG="$LOG_PATH/$(date '+%Y%m%d-%H%M%S').log"
COMMAND=("$BINARY" -d "$DATA_PATH" -u "$USER_PATH" "${EXTRA_ARGS[@]}")

print "PeonPad macOS runtime"
print "  profile: $PROFILE"
print "  data:    $DATA_PATH"
print "  user:    $USER_PATH"
print "  log:     $RUN_LOG"
printf '  command:'
printf ' %q' "${COMMAND[@]}"
printf '\n'

set +e
env HOME="$HOME_PATH" \
    TMPDIR="$TEMP_PATH" \
    XDG_CACHE_HOME="$CACHE_PATH" \
    "${COMMAND[@]}" 2>&1 | tee "$RUN_LOG"
ENGINE_STATUS=${pipestatus[1]}
set -e

exit "$ENGINE_STATUS"
