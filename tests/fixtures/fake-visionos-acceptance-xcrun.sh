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
    if [[ "$MODE" == startup-ready-only \
        || "$MODE" == startup-bracketed-fatal ]]; then
      /bin/date +%s > "$STATE_DIR/startup-epoch"
      sleep 2
    fi
    case "$MODE" in
      negative-readiness)
        print "PeonPad renderer is not ready" >> "$STDERR_FILE"
        ;;
      simulator-objc-noise)
        print "objc[$PID]: Class SimulatorAccessibilityClass is implemented in both /Library/Developer/CoreSimulator/Volumes/xrOS/RuntimeRoot/System/Library/PrivateFrameworks/First.framework/First (0x1000) and /Library/Developer/CoreSimulator/Volumes/xrOS/RuntimeRoot/System/Library/PrivateFrameworks/Second.framework/Second (0x2000). This may cause spurious casting failures and mysterious crashes. One of the duplicates must be removed or renamed." >> "$STDERR_FILE"
        print "PEONPAD_VISIONOS_READY=1" >> "$STDERR_FILE"
        ;;
      simulator-objc-near-miss)
        print "objc[$PID]: Class PeonPadRenderer is implemented in both /Library/Developer/CoreSimulator/Volumes/xrOS/RuntimeRoot/System/Library/PrivateFrameworks/First.framework/First (0x1000) and /tmp/PeonPadRenderer (0x2000). This may cause spurious casting failures and mysterious crashes. One of the duplicates must be removed or renamed." >> "$STDERR_FILE"
        print "PEONPAD_VISIONOS_READY=1" >> "$STDERR_FILE"
        ;;
      startup-ready-only) ;;
      *)
        print "PEONPAD_VISIONOS_READY=1" >> "$STDERR_FILE"
        ;;
    esac
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
      CURRENT_PID=$(<"$STATE_DIR/current-pid")
      START_EPOCH=""
      WANT_START=0
      for argument in "$@"; do
        if (( WANT_START )); then
          START_EPOCH=${argument#@}
          break
        fi
        [[ "$argument" == --start ]] && WANT_START=1
      done
      STARTUP_VISIBLE=1
      if [[ "$MODE" == startup-ready-only \
          || "$MODE" == startup-bracketed-fatal ]]; then
        LAUNCH_EPOCH=$(<"$STATE_DIR/startup-epoch")
        if [[ "$START_EPOCH" != <-> \
            || $START_EPOCH -gt $LAUNCH_EPOCH ]]; then
          STARTUP_VISIBLE=0
        fi
      fi
      case "$MODE" in
        runtime-fatal)
          print "Fake Vision Executable[$CURRENT_PID:abc] PeonPad Metal renderer failed"
          ;;
        startup-ready-only)
          if (( STARTUP_VISIBLE )); then
            print "Fake Vision Executable[$CURRENT_PID:abc] PEONPAD_VISIONOS_READY=1"
          fi
          ;;
        startup-bracketed-fatal)
          if (( STARTUP_VISIBLE )); then
            print "Fake Vision Executable[$CURRENT_PID:abc] [org.peonpad:render] PeonPad Metal renderer failed"
          fi
          ;;
        negative-readiness)
          print "Fake Vision Executable[$CURRENT_PID:abc] PeonPad renderer is not ready"
          ;;
        *)
          print "Fake Vision Executable[$CURRENT_PID:abc] [com.apple.Accessibility:AXLoading] Failed to load a system Framework"
          print "Fake Vision Executable[$CURRENT_PID:abc] [com.apple.BoardServices:XPCErrors] [C:4] Alloc 4101:FBWorkspace-org.peonpad.visionos"
          print "Fake Vision Executable[$CURRENT_PID:abc] [com.apple.FrontBoard:Scene] Invalidating scene: UISceneHosting-org.peonpad.visionos:UIHostedScene-com.apple.RealityKeyboard-11111111-1111-1111-1111-111111111111"
          print "Fake Vision Executable[$CURRENT_PID:abc] [com.apple.UIKit:KBProxyForwarding] Presentation environment invalidated: UISceneHosting-org.peonpad.visionos UIHostedScene-com.apple.RealityKeyboard-11111111-1111-1111-1111-111111111111"
          print "Fake Vision Executable[$CURRENT_PID:abc] PEONPAD_VISIONOS_READY=1"
          ;;
      esac
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
