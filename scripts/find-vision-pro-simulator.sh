#!/bin/zsh

set -eu

if (( $# != 0 )); then
  print -u2 "Usage: ./scripts/find-vision-pro-simulator.sh"
  exit 2
fi

[[ -x "$(command -v xcrun)" ]] || {
  print -u2 "xcrun is unavailable; select a full Xcode installation"
  exit 1
}

DEVICES=$(xcrun simctl list devices available)
REQUESTED_UDID=${PEONPAD_VISION_SIMULATOR_UDID:-}
if [[ -n "$REQUESTED_UDID" ]]; then
  if ! awk -v id="$REQUESTED_UDID" '
      /^-- visionOS / {in_vision_runtime = 1; next}
      /^-- / {in_vision_runtime = 0}
      in_vision_runtime && /Apple Vision Pro/ &&
          index($0, "(" id ")") {found = 1}
      END {exit !found}
    ' <<< "$DEVICES"; then
    print -u2 "requested Vision Pro simulator is not available: $REQUESTED_UDID"
    exit 1
  fi
  print "$REQUESTED_UDID"
  exit 0
fi

# simctl lists runtimes in ascending version order, so retain the final
# available Apple Vision Pro device from a visionOS runtime.
UDID=$(awk '
  /^-- visionOS / {in_vision_runtime = 1; next}
  /^-- / {in_vision_runtime = 0}
  in_vision_runtime && /Apple Vision Pro/ {
    if (match($0, /\([0-9A-F-]+\)/)) {
      udid = substr($0, RSTART + 1, RLENGTH - 2)
    }
  }
  END {print udid}
' <<< "$DEVICES")

[[ -n "$UDID" ]] || {
  print -u2 "no available Apple Vision Pro simulator was found"
  print -u2 "install a visionOS runtime in Xcode Settings > Components"
  exit 1
}

print "$UDID"
