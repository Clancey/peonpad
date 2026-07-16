#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  print "Usage: ./scripts/verify-visionos-bundle.sh <xrsimulator|xros> <app>"
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# != 2 )); then
  usage >&2
  exit 2
fi

TARGET=$1
APP=${2:A}
EXPECTED_BUNDLE_IDENTIFIER=${PEONPAD_VISIONOS_BUNDLE_IDENTIFIER:-org.peonpad.visionos}
case "$TARGET" in
  xrsimulator)
    EXPECTED_PLATFORM=12
    EXPECTED_SUPPORTED_PLATFORM=XRSimulator
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
  print -u2 "missing visionOS application bundle: $APP"
  exit 1
}
plutil -lint "$APP/Info.plist" >/dev/null

value() {
  plutil -extract "$1" raw "$APP/Info.plist"
}

[[ "$(value CFBundleIdentifier)" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || {
  print -u2 "unexpected visionOS bundle identifier"
  exit 1
}
[[ "$(value CFBundleExecutable)" == "PeonPadVisionShell" ]]
[[ "$(value CFBundleIcons.CFBundlePrimaryIcon)" == "AppIcon" ]]
[[ "$(value MinimumOSVersion)" == "2.0" ]]
[[ "$(value UIDeviceFamily.0)" == "7" ]]
[[ "$(value CFBundleSupportedPlatforms.0)" == \
    "$EXPECTED_SUPPORTED_PLATFORM" ]]
[[ "$(value UIApplicationPreferredDefaultSceneSessionRole)" == \
    "UIWindowSceneSessionRoleApplication" ]]
[[ "$(value UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes)" == \
    "false" ]]
[[ "$(value \
  UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneClassName)" == \
    "UIWindowScene" ]]
[[ "$(value \
  UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneDelegateClassName)" == \
    "SDLUIKitSceneDelegate" ]]
[[ "$(value UIApplicationSupportsIndirectInputEvents)" == "true" ]]

for forbidden_key in \
  'CFBundleIcons~ipad' \
  UIRequiresFullScreen \
  'UISupportedInterfaceOrientations~ipad'; do
  if plutil -extract "$forbidden_key" raw "$APP/Info.plist" \
      >/dev/null 2>&1; then
    print -u2 "iPad-only metadata entered visionOS bundle: $forbidden_key"
    exit 1
  fi
done

EXECUTABLE="$APP/PeonPadVisionShell"
[[ -x "$EXECUTABLE" ]] || {
  print -u2 "missing visionOS executable: $EXECUTABLE"
  exit 1
}
lipo -info "$EXECUTABLE" | grep -q 'architecture: arm64' || {
  print -u2 "visionOS executable is not arm64"
  exit 1
}
otool -l "$EXECUTABLE" | awk -v expected="$EXPECTED_PLATFORM" '
  $1 == "platform" {count++; if ($2 != expected) bad = 1}
  $1 == "minos" {if ($2 != "2.0") bad = 1}
  END {exit count == 0 || bad}
' || {
  print -u2 "visionOS executable has the wrong platform or minimum OS"
  exit 1
}

[[ -f "$APP/Assets.car" && -f "$APP/icon.png" \
    && -f "$APP/spring.wav" ]] || {
  print -u2 "public SDL3 smoke resources are missing"
  exit 1
}
sips -g pixelWidth -g pixelHeight "$APP/icon.png" \
  | grep -q 'pixelWidth:' || {
  print -u2 "bundled smoke image is invalid"
  exit 1
}
file "$APP/spring.wav" | grep -q 'WAVE audio' || {
  print -u2 "bundled smoke audio is invalid"
  exit 1
}

if [[ -d "$APP/Frameworks" ]]; then
  find "$APP/Frameworks" -type f -perm -111 -print0 |
    while IFS= read -r -d '' framework_binary; do
      otool -l "$framework_binary" | awk -v expected="$EXPECTED_PLATFORM" '
        $1 == "platform" {count++; if ($2 != expected) bad = 1}
        END {exit count == 0 || bad}
      '
    done
fi

otool -L "$EXECUTABLE" | tail -n +2 | awk '
  {
    dependency = $1
    if (dependency !~ "^/System/Library/" &&
        dependency !~ "^/usr/lib/" &&
        dependency !~ "^@rpath/") {
      print "unexpected linkage: " dependency > "/dev/stderr"
      bad = 1
    }
  }
  END {exit bad}
'
RPATHS=$(otool -l "$EXECUTABLE" | awk '
  $1 == "cmd" && $2 == "LC_RPATH" {want_path = 1; next}
  want_path && $1 == "path" {print $2; want_path = 0}
')
while IFS= read -r rpath; do
  [[ -z "$rpath" || "$rpath" == @executable_path/* \
      || "$rpath" == @loader_path/* ]] || {
    print -u2 "unsafe visionOS runtime path: $rpath"
    exit 1
  }
done <<< "$RPATHS"

PROPRIETARY_HIT=$(find "$APP" \
  \( -type d -iname 'data.Wargus' \
  -o -type f \( -iname '*.mpq' -o -iname '*.MPQ' \
  -o -iname 'INSTALL.EXE' -o -iname 'WAR2DAT.MPQ' \
  -o -iname 'setup_warcraft_ii_*' -o -iname '*.mobileprovision' \
  -o -iname '*.p12' \) \) -print -quit)
[[ -z "$PROPRIETARY_HIT" ]] || {
  print -u2 "forbidden private/proprietary content in bundle: $PROPRIETARY_HIT"
  exit 1
}

print "verified arm64 visionOS $TARGET smoke bundle: $APP"
print "  platform: $EXPECTED_PLATFORM; minimum: 2.0"
print "  scene:    SDLUIKitSceneDelegate / resizable UIWindowScene"
print "  content:  public SDL3 smoke fixtures only; no gameplay data"
