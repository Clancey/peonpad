#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}

usage() {
  cat <<'EOF'
Usage: ./scripts/open-visionos-simulator.sh <explicit-vision-pro-udid>

Validates the explicit Apple Vision Pro simulator and brings that one device to
the foreground for interactive use. Automated scripts must not call this helper.
EOF
}

if (( $# == 1 )) && [[ "$1" == (--help|-h) ]]; then
  usage
  exit 0
fi
(( $# == 1 )) || {
  usage >&2
  exit 2
}

UDID=$1
PEONPAD_VISION_SIMULATOR_UDID="$UDID" \
  "$SCRIPT_DIR/find-vision-pro-simulator.sh" >/dev/null
open -a Simulator --args -CurrentDeviceUDID "$UDID"
