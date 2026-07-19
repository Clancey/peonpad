#!/bin/zsh

set -eu

OUTPUT=udid
if (( $# == 1 )); then
  case "$1" in
    --details) OUTPUT=details ;;
    --help)
      print "Usage: ./scripts/find-vision-pro-simulator.sh [--details]"
      exit 0
      ;;
    *)
      print -u2 "Usage: ./scripts/find-vision-pro-simulator.sh [--details]"
      exit 2
      ;;
  esac
elif (( $# != 0 )); then
  print -u2 "Usage: ./scripts/find-vision-pro-simulator.sh [--details]"
  exit 2
fi

[[ -x "$(command -v xcrun)" ]] || {
  print -u2 "xcrun is unavailable; select a full Xcode installation"
  exit 1
}

DEVICES=$(xcrun simctl list devices available)
REQUESTED_UDID=${PEONPAD_VISION_SIMULATOR_UDID:-}
if [[ -n "$REQUESTED_UDID" ]]; then
  print -r -- "$REQUESTED_UDID" |
    grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || {
      print -u2 "requested Vision Pro simulator UDID is invalid"
      exit 1
    }
fi

# Prefer a booted device, then the newest semantic runtime, then the lowest
# canonical UDID so selection remains stable when several devices are present.
SELECTION=$(awk -v requested="$REQUESTED_UDID" '
  function version_score(version, parts, count, part_index, score) {
    count = split(version, parts, ".")
    score = 0
    for (part_index = 1; part_index <= 4; part_index++) {
      part = part_index <= count ? parts[part_index] + 0 : 0
      score = (score * 1000) + part
    }
    return score
  }

  /^-- visionOS [0-9]+([.][0-9]+)* --$/ {
    runtime = $0
    sub(/^-- /, "", runtime)
    sub(/ --$/, "", runtime)
    version = runtime
    sub(/^visionOS /, "", version)
    score = version_score(version)
    in_vision_runtime = 1
    next
  }
  /^-- / {
    in_vision_runtime = 0
    next
  }
  !in_vision_runtime {
    next
  }
  /^[[:space:]]*Apple Vision Pro \([0-9A-Fa-f-]+\) \((Booted|Shutdown)\)[[:space:]]*$/ {
    line = $0
    if (!match(line, /\([0-9A-Fa-f-]+\)/)) {
      next
    }
    udid = substr(line, RSTART + 1, RLENGTH - 2)
    state = line
    sub(/^.*\(/, "", state)
    sub(/\)[[:space:]]*$/, "", state)

    if (requested != "" && toupper(udid) != toupper(requested)) {
      next
    }

    booted = state == "Booted" ? 1 : 0
    if (!found || booted > best_booted ||
        (booted == best_booted && score > best_score) ||
        (booted == best_booted && score == best_score && udid < best_udid)) {
      found = 1
      best_udid = udid
      best_runtime = runtime
      best_state = state
      best_booted = booted
      best_score = score
    }
  }
  END {
    if (found) {
      printf "%s\tApple Vision Pro\t%s\t%s\n",
        best_udid, best_runtime, best_state
    }
  }
' <<< "$DEVICES")

[[ -n "$SELECTION" ]] || {
  if [[ -n "$REQUESTED_UDID" ]]; then
    print -u2 "requested simulator is not an available Apple Vision Pro on visionOS"
  else
    print -u2 "no available Apple Vision Pro simulator was found"
    print -u2 "install a visionOS runtime in Xcode Settings > Components"
  fi
  exit 1
}

if [[ "$OUTPUT" == details ]]; then
  print -r -- "$SELECTION"
else
  print -r -- "${SELECTION%%$'\t'*}"
fi
