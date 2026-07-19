#!/bin/zsh

set -eu

STATE_DIR=${PEONPAD_TEST_ACCEPTANCE_STATE_DIR:?}
DEVICES_FILE=${PEONPAD_TEST_SIMCTL_DEVICES_FILE:-$STATE_DIR/devices.txt}
MODE=${PEONPAD_TEST_ACCEPTANCE_MODE:-healthy}
mkdir -p "$STATE_DIR"
print -r -- "$*" >> "$STATE_DIR/xcrun.log"

if [[ "$1" == --sdk && "$3" == --show-sdk-version ]]; then
  case "$2" in
    xrsimulator|xros) print 26.5 ;;
    *) exit 1 ;;
  esac
  exit 0
fi

[[ "$1" == simctl ]] || exit 2
case "$2" in
  list)
    [[ "$3" == devices && "$4" == available ]] || exit 2
    if [[ -f "$STATE_DIR/booted" ]]; then
      sed 's/(Shutdown)/(Booted)/g' "$DEVICES_FILE"
    else
      /bin/cat "$DEVICES_FILE"
    fi
    ;;
  boot)
    print booted > "$STATE_DIR/booted"
    ;;
  bootstatus)
    [[ -f "$STATE_DIR/booted" ]] || grep -q '(Booted)' "$DEVICES_FILE"
    ;;
  install)
    APP=$4
    CONTAINER="$STATE_DIR/installed/Fake Vision Installed.app"
    rm -rf "$STATE_DIR/installed"
    mkdir -p "${CONTAINER:h}"
    cp -R "$APP" "$CONTAINER"
    print -r -- "$CONTAINER" > "$STATE_DIR/container-path"
    ;;
  get_app_container)
    [[ -f "$STATE_DIR/container-path" ]] || exit 1
    CONTAINER=$(<"$STATE_DIR/container-path")
    [[ -d "$CONTAINER" ]] || exit 1
    print -r -- "$CONTAINER"
    ;;
  launch)
    [[ "$MODE" != launch-failure ]] || exit 1
    STDOUT_FILE=""
    STDERR_FILE=""
    for argument in "$@"; do
      case "$argument" in
        --stdout=*) STDOUT_FILE=${argument#--stdout=} ;;
        --stderr=*) STDERR_FILE=${argument#--stderr=} ;;
      esac
    done
    [[ -n "$STDOUT_FILE" && -n "$STDERR_FILE" ]] || exit 2
    COUNT=0
    [[ ! -f "$STATE_DIR/launch-count" ]] ||
      COUNT=$(<"$STATE_DIR/launch-count")
    (( COUNT += 1 ))
    print "$COUNT" > "$STATE_DIR/launch-count"
    if [[ "$MODE" == stale-pid ]]; then
      PID=4101
    else
      PID=$(( 4100 + COUNT ))
    fi
    print "$PID" > "$STATE_DIR/current-pid"
    print "PeonPad automated fixture ready: launch $COUNT" >> "$STDERR_FILE"
    BUNDLE_ID=${@[-1]}
    print "$BUNDLE_ID: $PID"
    ;;
  spawn)
    if [[ "$4" == launchctl && "$5" == procinfo ]]; then
      [[ -f "$STATE_DIR/current-pid" ]] || exit 1
      [[ "$6" == "$(<"$STATE_DIR/current-pid")" ]] || exit 1
      print "program path = /fake/Fake Vision Executable"
      print "pid = $6"
      print "state = running"
      print "bundle id = org.peonpad.visionos"
    elif [[ "$4" == log && "$5" == show ]]; then
      if [[ "$MODE" == runtime-fatal ]]; then
        print "Fake Vision Executable[4101:abc] PeonPad Metal renderer failed"
      else
        print "Fake Vision Executable[4101:abc] [com.apple.Accessibility:AXLoading] Failed to load a system Framework"
        print "Fake Vision Executable[4101:abc] PeonPad automated fixture ready: unified log"
      fi
    else
      exit 2
    fi
    ;;
  io)
    [[ "$4" == screenshot ]] || exit 2
    print 'fake screenshot bytes' > "$5"
    ;;
  terminate)
    [[ -f "$STATE_DIR/current-pid" ]] || exit 1
    rm -f "$STATE_DIR/current-pid"
    ;;
  uninstall)
    rm -rf "$STATE_DIR/installed"
    rm -f "$STATE_DIR/container-path" "$STATE_DIR/current-pid"
    ;;
  *)
    exit 2
    ;;
esac
