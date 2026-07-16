#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  cat <<'EOF'
Usage: PEONPAD_VISIONOS_DEVICE_INSTALL=1 \
  ./scripts/install-visionos-device.sh <signed-app> <device-identifier>

The app must already be signed by Xcode for a paired Apple Vision Pro and
contain an embedded provisioning profile. This script never handles credentials.
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# != 2 )); then
  usage >&2
  exit 2
fi
[[ "${PEONPAD_VISIONOS_DEVICE_INSTALL:-0}" == 1 ]] || {
  print -u2 "device installation requires PEONPAD_VISIONOS_DEVICE_INSTALL=1"
  exit 1
}

APP=${1:A}
DEVICE=$2
[[ -d "$APP" && -f "$APP/Info.plist" ]] || {
  print -u2 "missing signed visionOS app: $APP"
  exit 1
}
EXECUTABLE_NAME=$(plutil -extract CFBundleExecutable raw "$APP/Info.plist")
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
EXECUTABLE="$APP/$EXECUTABLE_NAME"
otool -l "$EXECUTABLE" | awk '
  $1 == "platform" {count++; if ($2 != 11) bad = 1}
  END {exit count == 0 || bad}
' || {
  print -u2 "device install gate rejected a non-xros app"
  exit 1
}
[[ -f "$APP/embedded.mobileprovision" ]] || {
  print -u2 "device install gate requires Xcode provisioning"
  exit 1
}
codesign --verify --deep --strict "$APP"

DEVICE_RECORD=$(xcrun devicectl list devices | grep -F "$DEVICE" || true)
[[ "$DEVICE_RECORD" == *"Apple Vision Pro"* ]] || {
  print -u2 "device identifier is not a paired Apple Vision Pro"
  exit 1
}

xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
print "requested signed visionOS app install and launch on Apple Vision Pro"
