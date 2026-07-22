#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  print "Usage: ./scripts/verify-tabletop-bundle.sh <xrsimulator|xros> <app> [--signed]"
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# != 2 && $# != 3 )); then
  usage >&2
  exit 2
fi

TARGET=$1
APP=${2:A}
SIGNED=0
if (( $# == 3 )); then
  [[ "$3" == --signed ]] || {
    usage >&2
    exit 2
  }
  SIGNED=1
fi

EXPECTED_BUNDLE_IDENTIFIER=${PEONPAD_TABLETOP_BUNDLE_IDENTIFIER:-org.peonpad.tabletop}
case "$TARGET" in
  xrsimulator)
    EXPECTED_PLATFORM=12
    EXPECTED_SUPPORTED_PLATFORM=XRSimulator
    (( SIGNED == 0 )) || {
      print -u2 "--signed is only valid for xros"
      exit 2
    }
    ;;
  xros)
    EXPECTED_PLATFORM=11
    EXPECTED_SUPPORTED_PLATFORM=XROS
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

[[ -d "$APP" && -f "$APP/Info.plist" ]] || {
  print -u2 "missing tabletop application bundle: $APP"
  exit 1
}
plutil -lint "$APP/Info.plist" >/dev/null
value() {
  plutil -extract "$1" raw "$APP/Info.plist"
}

[[ "$(value CFBundleIdentifier)" == "$EXPECTED_BUNDLE_IDENTIFIER" ]]
[[ "$(value CFBundleExecutable)" == PeonPadTabletop ]]
[[ "$(value CFBundleIcons.CFBundlePrimaryIcon)" == AppIcon ]]
[[ "$(value CFBundleSupportedPlatforms.0)" == "$EXPECTED_SUPPORTED_PLATFORM" ]]
[[ "$(value UIDeviceFamily.0)" == 7 ]]
[[ "$(value UIApplicationPreferredDefaultSceneSessionRole)" == \
  UIWindowSceneSessionRoleVolumetricApplication ]]
[[ "$(value UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes)" == false ]]
[[ "$(value \
  UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleVolumetricApplication.0.UISceneClassName)" == UIWindowScene ]]
if plutil -extract \
    UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneDelegateClassName \
    raw "$APP/Info.plist" >/dev/null 2>&1; then
  print -u2 "SDL/UIKit scene ownership entered the SwiftUI tabletop bundle"
  exit 1
fi

EXECUTABLE="$APP/PeonPadTabletop"
[[ -x "$EXECUTABLE" ]]
[[ "$(lipo -archs "$EXECUTABLE")" == arm64 ]]
otool -l "$EXECUTABLE" | awk -v expected="$EXPECTED_PLATFORM" '
  $1 == "platform" {count++; if ($2 != expected) bad = 1}
  $1 == "minos" {minimum++}
  $1 == "sdk" {sdk++}
  END {exit count == 0 || minimum == 0 || sdk == 0 || bad}
'
DEPENDENCIES=$(otool -L "$EXECUTABLE")
print -r -- "$DEPENDENCIES" | grep -q '/SwiftUI.framework/SwiftUI'
print -r -- "$DEPENDENCIES" | grep -q '/RealityKit.framework/RealityKit'
[[ -s "$APP/Assets.car" ]]
ASSET_INFO=$(xcrun assetutil --info "$APP/Assets.car")
print -r -- "$ASSET_INFO" | grep -q '"Name" : "AppIcon"'

PROPRIETARY_HIT=$(find "$APP" \
  \( -type d \( -iname 'data.Wargus' -o -iname 'ref' \) \
  -o -type f \( -iname '*.mpq' -o -iname 'INSTALL.EXE' \
  -o -iname 'WAR2DAT.MPQ' -o -iname '*.p12' -o -iname '*.cer' \
  -o -iname '*.keychain*' \) \) -print -quit)
[[ -z "$PROPRIETARY_HIT" ]] || {
  print -u2 "forbidden private/proprietary content in tabletop bundle"
  exit 1
}

if [[ "$TARGET" == xrsimulator ]]; then
  codesign --verify --deep --strict "$APP"
elif (( SIGNED )); then
  [[ -f "$APP/embedded.mobileprovision" ]] || {
    print -u2 "signed device build is missing its provisioning profile"
    exit 1
  }
  codesign --verify --deep --strict "$APP"
else
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    print -u2 "unsigned device build was unexpectedly signed"
    exit 1
  fi
fi

print "verified native volumetric tabletop bundle: $APP"
print "  platform: $EXPECTED_PLATFORM / $EXPECTED_SUPPORTED_PLATFORM"
print "  runtime:  SwiftUI + RealityKit; SDL scene delegate absent"
print "  content:  procedural foundation; proprietary content absent"
