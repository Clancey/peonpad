#!/bin/zsh

set -eu

(( $# == 4 )) || exit 2
TARGET=$1
APP=$2
[[ "$3" == --metadata && -d "$APP" ]] || exit 2
METADATA=$4

case "$TARGET" in
  xrsimulator)
    platform=12
    supported_platform=XRSimulator
    signature=adhoc
    ;;
  xros)
    platform=11
    supported_platform=XROS
    signature=unsigned
    ;;
  *)
    exit 2
    ;;
esac

PLIST="${METADATA}.plist"
mkdir -p "${METADATA:h}"
plutil -create xml1 "$PLIST"
plutil -insert bundle_identifier -string org.peonpad.visionos "$PLIST"
plutil -insert executable -string "Fake Vision Executable" "$PLIST"
plutil -insert platform -integer "$platform" "$PLIST"
plutil -insert minimum_os -string 2.0 "$PLIST"
plutil -insert sdk -string 26.5 "$PLIST"
plutil -insert supported_platform -string "$supported_platform" "$PLIST"
plutil -insert signature -string "$signature" "$PLIST"
plutil -insert primary_icon -string AppIcon "$PLIST"
plutil -insert resource_count -integer 3 "$PLIST"
plutil -insert framework_count -integer 0 "$PLIST"
plutil -convert json -o "$METADATA" "$PLIST"
rm -f "$PLIST"
