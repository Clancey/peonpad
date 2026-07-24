#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
MANAGER="$ROOT_DIR/scripts/visionos-simulator.sh"
FAKE_SIMCTL="$SCRIPT_DIR/fixtures/fake-visionos-simctl.sh"
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/peonpad-simulator-isolation.XXXXXX")
STATE_ROOT="$TEMP_ROOT/ownership"
SIM_STATE="$TEMP_ROOT/simctl"
USER_UDID=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
mkdir -p "$SIM_STATE"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

run_manager() {
  env \
    PEONPAD_VISIONOS_SIMULATOR_STATE_ROOT="$STATE_ROOT" \
    PEONPAD_SIMCTL_BIN="$FAKE_SIMCTL" \
    PEONPAD_TEST_SIMULATOR_STATE_DIR="${PEONPAD_TEST_SIMULATOR_STATE_DIR_OVERRIDE:-$SIM_STATE}" \
    PEONPAD_TEST_USER_DEVICE="$USER_UDID" \
    "$MANAGER" "$@"
}

STATE_ONE=$(run_manager create --label first)
DETAILS_ONE=$(run_manager details --state "$STATE_ONE")
IFS=$'\t' read -r UDID_ONE NAME_ONE RUNTIME_ONE STATUS_ONE <<< "$DETAILS_ONE"
[[ "$NAME_ONE" == "PeonPad Agent "* && "$RUNTIME_ONE" == "visionOS 26.5" ]]
[[ "$STATUS_ONE" == Booted && "$UDID_ONE" != "$USER_UDID" ]]

STATE_TWO=$(PEONPAD_TEST_CREATE_INDEX=2 run_manager create --label concurrent)
UDID_TWO=${$(run_manager details --state "$STATE_TWO")%%$'\t'*}
[[ "$STATE_ONE" != "$STATE_TWO" && "$UDID_ONE" != "$UDID_TWO" ]]

if run_manager assert --udid "$USER_UDID" >/dev/null 2>&1; then
  print -u2 "manager accepted an unowned user simulator"
  exit 1
fi
run_manager assert --udid "$USER_UDID" --allow-user-simulator
if run_manager assert --udid booted --allow-user-simulator >/dev/null 2>&1; then
  print -u2 "manager accepted the ambiguous booted target"
  exit 1
fi

APP="$TEMP_ROOT/Test.app"
mkdir -p "$APP"
run_manager install --state "$STATE_ONE" --udid "$UDID_ONE" --app "$APP"
LAUNCH_OUTPUT=$(run_manager launch --state "$STATE_ONE" --udid "$UDID_ONE" \
  --bundle org.peonpad.test --env PEONPAD_TABLETOP_COMMAND_HARNESS=1)
[[ "$LAUNCH_OUTPUT" == "org.peonpad.test: 9001" ]]
grep -Fq "SIMCTL_CHILD_PEONPAD_TABLETOP_COMMAND_HARNESS=1" \
  "$SIM_STATE/child-env.log" || {
    print -u2 "child environment was not scoped through SIMCTL_CHILD_"
    exit 1
  }
SCREENSHOT="$TEMP_ROOT/screenshot.png"
run_manager screenshot --state "$STATE_ONE" --udid "$UDID_ONE" \
  --output "$SCREENSHOT"
[[ -s "$SCREENSHOT" ]]

if PEONPAD_TEST_CLEANUP_FAILURE=delete run_manager cleanup \
    --state "$STATE_ONE" >/dev/null 2>&1; then
  print -u2 "cleanup ignored a simulator deletion failure"
  exit 1
fi
[[ -f "$STATE_ONE/ownership.plist" ]]
run_manager cleanup --state "$STATE_ONE"
[[ ! -e "$STATE_ONE" ]]
PEONPAD_TEST_SIMULATOR_STATE_DIR="$SIM_STATE" \
  PEONPAD_TEST_USER_DEVICE="$USER_UDID" \
  "$FAKE_SIMCTL" list devices | grep -q "($USER_UDID) (Booted)" || {
    print -u2 "cleanup touched the user's active simulator"
    exit 1
  }

run_manager cleanup --state "$STATE_TWO"
[[ ! -e "$STATE_TWO" ]]

CONCURRENT_ONE_STATE="$TEMP_ROOT/concurrent-one"
CONCURRENT_TWO_STATE="$TEMP_ROOT/concurrent-two"
mkdir -p "$CONCURRENT_ONE_STATE" "$CONCURRENT_TWO_STATE"
env PEONPAD_VISIONOS_SIMULATOR_STATE_ROOT="$STATE_ROOT" \
  PEONPAD_SIMCTL_BIN="$FAKE_SIMCTL" \
  PEONPAD_TEST_SIMULATOR_STATE_DIR="$CONCURRENT_ONE_STATE" \
  PEONPAD_TEST_CREATE_INDEX=3 \
  "$MANAGER" create --label parallel-one > "$TEMP_ROOT/parallel-one.out" &
PARALLEL_ONE_PID=$!
env PEONPAD_VISIONOS_SIMULATOR_STATE_ROOT="$STATE_ROOT" \
  PEONPAD_SIMCTL_BIN="$FAKE_SIMCTL" \
  PEONPAD_TEST_SIMULATOR_STATE_DIR="$CONCURRENT_TWO_STATE" \
  PEONPAD_TEST_CREATE_INDEX=4 \
  "$MANAGER" create --label parallel-two > "$TEMP_ROOT/parallel-two.out" &
PARALLEL_TWO_PID=$!
wait "$PARALLEL_ONE_PID"
wait "$PARALLEL_TWO_PID"
PARALLEL_ONE=$(<"$TEMP_ROOT/parallel-one.out")
PARALLEL_TWO=$(<"$TEMP_ROOT/parallel-two.out")
[[ "$PARALLEL_ONE" != "$PARALLEL_TWO" ]]
PEONPAD_TEST_SIMULATOR_STATE_DIR_OVERRIDE="$CONCURRENT_ONE_STATE" \
  run_manager cleanup --state "$PARALLEL_ONE"
PEONPAD_TEST_SIMULATOR_STATE_DIR_OVERRIDE="$CONCURRENT_TWO_STATE" \
  run_manager cleanup --state "$PARALLEL_TWO"

STALE_STATE=$(run_manager create --label stale)
plutil -replace created_epoch -integer 1 "$STALE_STATE/ownership.plist"
plutil -replace owner_pid -integer 999999 "$STALE_STATE/ownership.plist"
run_manager reap-stale --older-than 1
[[ ! -e "$STALE_STATE" ]]

LIVE_STATE=$(run_manager create --label live-owner --owner-pid $$)
plutil -replace created_epoch -integer 1 "$LIVE_STATE/ownership.plist"
run_manager reap-stale --older-than 1
[[ -e "$LIVE_STATE/ownership.plist" ]]
run_manager cleanup --state "$LIVE_STATE"

INTERRUPTED_STATE=$(run_manager create --label interrupted-cleanup)
INTERRUPTED_UDID=${$(run_manager details --state "$INTERRUPTED_STATE")%%$'\t'*}
PEONPAD_TEST_SIMULATOR_STATE_DIR="$SIM_STATE" \
  "$FAKE_SIMCTL" delete "$INTERRUPTED_UDID"
run_manager cleanup --state "$INTERRUPTED_STATE"
[[ ! -e "$INTERRUPTED_STATE" ]]

SIGNAL_SIM_STATE="$TEMP_ROOT/signal-simctl"
mkdir -p "$SIGNAL_SIM_STATE"
env PEONPAD_VISIONOS_SIMULATOR_STATE_ROOT="$STATE_ROOT" \
  PEONPAD_SIMCTL_BIN="$FAKE_SIMCTL" \
  PEONPAD_TEST_SIMULATOR_STATE_DIR="$SIGNAL_SIM_STATE" \
  PEONPAD_TEST_CREATE_INDEX=5 \
  PEONPAD_TEST_CREATE_DELAY=1 \
  "$MANAGER" create --label signal --owner-pid $$ \
  >"$TEMP_ROOT/signal.out" 2>"$TEMP_ROOT/signal.err" &
SIGNAL_CREATE_PID=$!
for _ in {1..50}; do
  [[ -s "$SIGNAL_SIM_STATE/devices" ]] && break
  sleep 0.02
done
kill -TERM "$SIGNAL_CREATE_PID"
wait "$SIGNAL_CREATE_PID" >/dev/null 2>&1 || :
[[ -z "$(grep 'PeonPad Agent' "$SIGNAL_SIM_STATE/devices" || :)" ]]
[[ -z "$(find "$STATE_ROOT" -name ownership.plist \
  -exec plutil -extract name raw {} \; 2>/dev/null |
  grep 'signal' || :)" ]]

print "visionOS simulator isolation regressions passed"
