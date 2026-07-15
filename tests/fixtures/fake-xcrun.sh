#!/bin/zsh

set -eu

[[ "$*" == "simctl list devices available" ]] || {
  print -u2 "unexpected fake xcrun arguments: $*"
  exit 2
}
[[ -f "${PEONPAD_TEST_SIMCTL_DEVICES_FILE:-}" ]] || {
  print -u2 "missing fake simctl devices file"
  exit 1
}

/bin/cat "$PEONPAD_TEST_SIMCTL_DEVICES_FILE"
