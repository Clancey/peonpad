#!/bin/zsh

set -eu

STATE_DIR=${PEONPAD_TEST_SIMULATOR_STATE_DIR:?}
mkdir -p "$STATE_DIR"
print -r -- "$*" >> "$STATE_DIR/calls.log"

RUNTIME_ID=com.apple.CoreSimulator.SimRuntime.xrOS-26-5
DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro

render_devices() {
  print -r -- "-- visionOS 26.5 --"
  [[ ! -f "$STATE_DIR/devices" ]] || cat "$STATE_DIR/devices"
  if [[ -n "${PEONPAD_TEST_USER_DEVICE:-}" ]]; then
    print "    Apple Vision Pro (${PEONPAD_TEST_USER_DEVICE}) (Booted)"
  fi
}

case "$1" in
  list)
    case "$2" in
      runtimes)
        print "visionOS 26.5 (23O123) - $RUNTIME_ID"
        ;;
      devicetypes)
        print "Apple Vision Pro ($DEVICE_TYPE)"
        ;;
      devices)
        render_devices
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  create)
    [[ "$3" == "$DEVICE_TYPE" && "$4" == "$RUNTIME_ID" ]]
    UDID=$(printf '%08X-0000-4000-8000-%012d' \
      "$(( (${PEONPAD_TEST_CREATE_INDEX:-1}) ))" \
      "$(( (${PEONPAD_TEST_CREATE_INDEX:-1}) ))")
    print -r -- "$2	$UDID	Shutdown" >> "$STATE_DIR/records"
    print "    $2 ($UDID) (Shutdown)" >> "$STATE_DIR/devices"
    [[ -z "${PEONPAD_TEST_CREATE_DELAY:-}" ]] ||
      sleep "$PEONPAD_TEST_CREATE_DELAY"
    print -r -- "$UDID"
    ;;
  boot)
    sed -i '' "s/($2) (Shutdown)/($2) (Booted)/" "$STATE_DIR/devices"
    ;;
  bootstatus)
    grep -q "($2) (Booted)" "$STATE_DIR/devices"
    print "Device already booted, nothing to do."
    ;;
  shutdown)
    if [[ "${PEONPAD_TEST_CLEANUP_FAILURE:-}" == shutdown ]]; then
      exit 1
    fi
    sed -i '' "s/($2) (Booted)/($2) (Shutdown)/" "$STATE_DIR/devices"
    ;;
  delete)
    [[ "${PEONPAD_TEST_CLEANUP_FAILURE:-}" != delete ]] || exit 1
    grep -v "($2)" "$STATE_DIR/devices" > "$STATE_DIR/devices.next" || :
    mv "$STATE_DIR/devices.next" "$STATE_DIR/devices"
    ;;
  install)
    [[ -d "$3" ]]
    print -r -- "$2	$3" > "$STATE_DIR/install"
    ;;
  launch)
    env | grep '^SIMCTL_CHILD_' >> "$STATE_DIR/child-env.log" || :
    print "org.peonpad.test: 9001"
    ;;
  get_app_container)
    mkdir -p "$STATE_DIR/container"
    print -r -- "$STATE_DIR/container"
    ;;
  io)
    [[ "$3" == screenshot ]]
    print screenshot > "$4"
    ;;
  terminate)
    ;;
  *)
    exit 2
    ;;
esac
