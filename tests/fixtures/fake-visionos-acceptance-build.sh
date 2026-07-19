#!/bin/zsh

set -eu

(( $# == 1 )) || exit 2
case "$1" in
  xrsimulator) supported_platform=XRSimulator ;;
  xros) supported_platform=XROS ;;
  *) exit 2 ;;
esac

BUILD_DIR=${PEONPAD_VISIONOS_BUILD_DIR:?}
STATE_DIR=${PEONPAD_TEST_ACCEPTANCE_STATE_DIR:?}
APP="$BUILD_DIR/Fake Vision App.app"
mkdir -p "$APP" "$STATE_DIR"

plutil -create xml1 "$APP/Info.plist"
plutil -insert CFBundleIdentifier -string org.peonpad.visionos "$APP/Info.plist"
plutil -insert CFBundleExecutable -string "Fake Vision Executable" "$APP/Info.plist"
plutil -insert CFBundleSupportedPlatforms -array "$APP/Info.plist"
plutil -insert CFBundleSupportedPlatforms.0 -string \
  "$supported_platform" "$APP/Info.plist"
plutil -insert MinimumOSVersion -string 2.0 "$APP/Info.plist"
print '#!/bin/sh' > "$APP/Fake Vision Executable"
print 'exit 0' >> "$APP/Fake Vision Executable"
chmod +x "$APP/Fake Vision Executable"
print 'fake compiled assets' > "$APP/Assets.car"

print -r -- "$1	$APP" >> "$STATE_DIR/builds.log"
