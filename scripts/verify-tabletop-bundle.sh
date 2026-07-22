#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  print "Usage: ./scripts/verify-tabletop-bundle.sh <xrsimulator|xros> <app> [--metadata PATH]"
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# != 2 && $# != 4 )); then
  usage >&2
  exit 2
fi

TARGET=$1
APP=${2:A}
METADATA=""
if (( $# == 4 )); then
  [[ "$3" == --metadata ]] || {
    usage >&2
    exit 2
  }
  METADATA=${4:A}
fi
EXPECTED_BUNDLE_IDENTIFIER=${PEONPAD_TABLETOP_BUNDLE_IDENTIFIER:-org.peonpad.visionos.tabletop}
MINIMUM_FLOOR=2.0
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

ASSET_INFO_FILE=""
cleanup_temp_files() {
  [[ -z "$ASSET_INFO_FILE" ]] || rm -f "$ASSET_INFO_FILE" >/dev/null 2>&1 || :
}
trap cleanup_temp_files EXIT

[[ -d "$APP" && -f "$APP/Info.plist" ]] || {
  print -u2 "missing visionOS tabletop application bundle: $APP"
  exit 1
}
plutil -lint "$APP/Info.plist" >/dev/null

value() {
  plutil -extract "$1" raw "$APP/Info.plist"
}

require_value() {
  local key=$1
  local expected=$2
  local description=$3
  local actual
  actual=$(value "$key") || {
    print -u2 "missing visionOS tabletop metadata: $description"
    exit 1
  }
  [[ "$actual" == "$expected" ]] || {
    print -u2 "unexpected visionOS tabletop metadata: $description"
    exit 1
  }
}

BUNDLE_IDENTIFIER=$(value CFBundleIdentifier)
EXECUTABLE_NAME=$(value CFBundleExecutable)
PRIMARY_ICON=$(value CFBundleIcons.CFBundlePrimaryIcon)
PLIST_MINIMUM=$(value MinimumOSVersion)
SUPPORTED_PLATFORM=$(value CFBundleSupportedPlatforms.0)

version_at_least() {
  awk -v actual="$1" -v floor="$2" '
    BEGIN {
      actual_count = split(actual, actual_parts, ".")
      floor_count = split(floor, floor_parts, ".")
      count = actual_count > floor_count ? actual_count : floor_count
      for (part_index = 1; part_index <= count; part_index++) {
        actual_part = 0
        floor_part = 0
        if (part_index <= actual_count) {
          actual_part = actual_parts[part_index] + 0
        }
        if (part_index <= floor_count) {
          floor_part = floor_parts[part_index] + 0
        }
        if (actual_part > floor_part) exit 0
        if (actual_part < floor_part) exit 1
      }
      exit 0
    }
  '
}

[[ "$BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || {
  print -u2 "unexpected visionOS tabletop bundle identifier"
  exit 1
}
# The tabletop app must never collide with the SDL3 smoke shell's bundle id,
# so both can be installed side by side in the simulator.
[[ "$BUNDLE_IDENTIFIER" != "org.peonpad.visionos" ]] || {
  print -u2 "visionOS tabletop bundle identifier collides with the smoke shell"
  exit 1
}
[[ -n "$EXECUTABLE_NAME" && "$EXECUTABLE_NAME" != */* ]] || {
  print -u2 "invalid visionOS tabletop bundle executable"
  exit 1
}
[[ "$PRIMARY_ICON" == AppIcon ]] || {
  print -u2 "visionOS tabletop primary icon must be AppIcon"
  exit 1
}
version_at_least "$PLIST_MINIMUM" "$MINIMUM_FLOOR" || {
  print -u2 "visionOS tabletop Info.plist minimum OS is below $MINIMUM_FLOOR"
  exit 1
}
require_value UIDeviceFamily.0 7 "UIDeviceFamily"
[[ "$(value UIDeviceFamily)" == "1" ]] || {
  print -u2 "visionOS tabletop bundle must declare only UIDeviceFamily 7"
  exit 1
}
[[ "$SUPPORTED_PLATFORM" == "$EXPECTED_SUPPORTED_PLATFORM" ]] || {
  print -u2 "unexpected visionOS tabletop supported platform"
  exit 1
}
[[ "$(value CFBundleSupportedPlatforms)" == "1" ]] || {
  print -u2 "visionOS tabletop bundle contains an unexpected additional platform"
  exit 1
}
# This is a plain SwiftUI-lifecycle app (App/Scene/ImmersiveSpace), not the
# SDL3 shell's UIKit scene delegate -- it must not carry that delegate's
# manifest shape, which would indicate the two bundles got mixed up. The
# tabletop app *does* need multiple-scene support (true, unlike the SDL3
# shell) so its 2D launcher window and its ImmersiveSpace board can be open
# at the same time.
require_value UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes \
  true "multiple-scene policy"
if plutil -extract \
    UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneDelegateClassName \
    raw "$APP/Info.plist" >/dev/null 2>&1; then
  print -u2 "visionOS tabletop bundle must not declare an SDL scene delegate"
  exit 1
fi
require_value UIApplicationSupportsIndirectInputEvents true \
  "indirect input support"
HAND_TRACKING_DESCRIPTION=$(value NSHandsTrackingUsageDescription) || {
  print -u2 "visionOS tabletop bundle is missing a hand tracking usage description"
  exit 1
}
[[ -n "$HAND_TRACKING_DESCRIPTION" ]] || {
  print -u2 "visionOS tabletop bundle is missing a hand tracking usage description"
  exit 1
}

for forbidden_key in \
  'CFBundleIcons~ipad' \
  UIRequiresFullScreen \
  'UISupportedInterfaceOrientations~ipad'; do
  if plutil -extract "$forbidden_key" raw "$APP/Info.plist" \
      >/dev/null 2>&1; then
    print -u2 "iPad-only metadata entered visionOS tabletop bundle: $forbidden_key"
    exit 1
  fi
done

EXECUTABLE="$APP/$EXECUTABLE_NAME"
[[ -x "$EXECUTABLE" ]] || {
  print -u2 "missing visionOS tabletop executable: $EXECUTABLE"
  exit 1
}
[[ "$(lipo -archs "$EXECUTABLE")" == "arm64" ]] || {
  print -u2 "visionOS tabletop executable is not arm64"
  exit 1
}
LOAD_COMMANDS=$(otool -l "$EXECUTABLE")
print -r -- "$LOAD_COMMANDS" | awk \
    -v expected="$EXPECTED_PLATFORM" -v floor="$MINIMUM_FLOOR" '
  function version_at_least(actual, minimum,
                            actual_parts, minimum_parts,
                            actual_count, minimum_count, count, part_index) {
    actual_count = split(actual, actual_parts, ".")
    minimum_count = split(minimum, minimum_parts, ".")
    count = actual_count > minimum_count ? actual_count : minimum_count
    for (part_index = 1; part_index <= count; part_index++) {
      actual_part = 0
      minimum_part = 0
      if (part_index <= actual_count) {
        actual_part = actual_parts[part_index] + 0
      }
      if (part_index <= minimum_count) {
        minimum_part = minimum_parts[part_index] + 0
      }
      if (actual_part > minimum_part) return 1
      if (actual_part < minimum_part) return 0
    }
    return 1
  }
  $1 == "platform" {
    platform_count++
    if ($2 != expected) bad = 1
  }
  $1 == "minos" {
    minimum_count++
    if (!version_at_least($2, floor)) bad = 1
  }
  $1 == "sdk" {
    sdk_count++
    if (!version_at_least($2, floor)) bad = 1
  }
  END {
    exit platform_count == 0 || minimum_count == 0 || sdk_count == 0 || bad
  }
' || {
  print -u2 "visionOS tabletop executable has the wrong platform, minimum OS, or SDK"
  exit 1
}
MACHO_MINIMUM=$(print -r -- "$LOAD_COMMANDS" |
  awk '$1 == "minos" {print $2; exit}')
MACHO_SDK=$(print -r -- "$LOAD_COMMANDS" |
  awk '$1 == "sdk" {print $2; exit}')

[[ -s "$APP/Assets.car" ]] || {
  print -u2 "compiled visionOS tabletop icon/resource catalog is missing"
  exit 1
}
if ! ASSET_CATALOG_INFO=$(xcrun assetutil --info "$APP/Assets.car"); then
  print -u2 "compiled visionOS tabletop asset catalog could not be inspected"
  exit 1
fi
ASSET_INFO_FILE=$(mktemp \
  "${TMPDIR:-/tmp}/peonpad-tabletop-assets.XXXXXX") || {
  print -u2 "could not create the asset catalog inspection file"
  exit 1
}
print -r -- "$ASSET_CATALOG_INFO" > "$ASSET_INFO_FILE" || {
  print -u2 "compiled visionOS tabletop asset catalog output could not be recorded"
  exit 1
}
plutil -convert xml1 -o /dev/null "$ASSET_INFO_FILE" || {
  print -u2 "compiled visionOS tabletop asset catalog output is invalid"
  exit 1
}
ASSET_INDEX=0
HAS_COMPILED_APP_ICON=0
while plutil -extract "$ASSET_INDEX" xml1 -o /dev/null \
    "$ASSET_INFO_FILE" 2>/dev/null; do
  ASSET_TYPE=$(plutil -extract "$ASSET_INDEX.AssetType" raw \
    "$ASSET_INFO_FILE" 2>/dev/null) || ASSET_TYPE=""
  if [[ "$ASSET_TYPE" == SolidImageStack ]]; then
    ASSET_NAME=$(plutil -extract "$ASSET_INDEX.Name" raw \
      "$ASSET_INFO_FILE") || {
      print -u2 "compiled visionOS tabletop solid image stack is missing its name"
      exit 1
    }
    [[ "$ASSET_NAME" != AppIcon ]] || HAS_COMPILED_APP_ICON=1
  fi
  (( ASSET_INDEX += 1 ))
done
(( HAS_COMPILED_APP_ICON )) || {
  print -u2 "compiled visionOS tabletop asset catalog does not contain AppIcon"
  exit 1
}
rm -f "$ASSET_INFO_FILE" || {
  print -u2 "asset catalog inspection file could not be removed"
  exit 1
}
ASSET_INFO_FILE=""

if ! DEPENDENCIES=$(otool -L "$EXECUTABLE" |
    awk 'NR > 1 {print $1}'); then
  print -u2 "visionOS tabletop dependencies could not be inspected"
  exit 1
fi
if [[ -n "$DEPENDENCIES" ]]; then
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      @rpath/*)
        relative_dependency=${dependency#@rpath/}
        case "/$relative_dependency/" in
          */../*)
            print -u2 "embedded visionOS tabletop dependency contains parent traversal"
            exit 1
            ;;
        esac
        [[ -f "$APP/Frameworks/$relative_dependency" ]] || {
          print -u2 "missing embedded visionOS tabletop dependency: $relative_dependency"
          exit 1
        }
        ;;
      *)
        print -u2 "unexpected visionOS tabletop linkage: $dependency"
        exit 1
        ;;
    esac
  done <<< "$DEPENDENCIES"
fi

PROPRIETARY_HIT=$(find "$APP" \
  \( -type d \( -iname 'data.Wargus' -o -iname 'ref' \) \
  -o -type f \( -iname '*.mpq' -o -iname '*.MPQ' \
  -o -iname 'INSTALL.EXE' -o -iname 'WAR2DAT.MPQ' \
  -o -iname 'setup_warcraft_ii_*' -o -iname '.env' \
  -o -iname '.env.*' -o -iname '*.mobileprovision' \
  -o -iname '*.provisionprofile' -o -iname '*.p12' \
  -o -iname '*.cer' -o -iname '*.keychain' \
  -o -iname '*.keychain-db' \) \) -print -quit)
[[ -z "$PROPRIETARY_HIT" ]] || {
  print -u2 "forbidden private/proprietary content in bundle: ${PROPRIETARY_HIT#$APP/}"
  exit 1
}

if [[ "$TARGET" == xrsimulator ]]; then
  codesign --verify --deep --strict "$APP" || {
   print -u2 "visionOS tabletop Simulator bundle signature verification failed"
   exit 1
  }
  SIGNATURE_DETAILS=$(codesign -dvv "$APP" 2>&1)
  print -r -- "$SIGNATURE_DETAILS" | grep -q '^Signature=adhoc$' || {
   print -u2 "visionOS tabletop Simulator bundle is not ad-hoc signed"
   exit 1
  }
  SIGNATURE=adhoc
else
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
   print -u2 "xros command-line tabletop bundle was unexpectedly signed"
   exit 1
  fi
  SIGNING_ARTIFACT=$(find "$APP" \
   \( -type d -name _CodeSignature \
   -o -type f \( -name CodeResources \
   -o -name embedded.mobileprovision \) \) -print -quit)
  [[ -z "$SIGNING_ARTIFACT" ]] || {
   print -u2 "xros command-line tabletop bundle contains signing artifacts"
   exit 1
  }
  SIGNATURE=unsigned
fi

RESOURCE_COUNT=$(find "$APP" -type f | wc -l | tr -d '[:space:]')
if [[ -n "$METADATA" ]]; then
  mkdir -p "${METADATA:h}"
  METADATA_PLIST="${METADATA}.plist.$$"
  METADATA_JSON="${METADATA}.json.$$"
  rm -f "$METADATA_PLIST" "$METADATA_JSON"
  plutil -create xml1 "$METADATA_PLIST"
  plutil -insert bundle_identifier -string "$BUNDLE_IDENTIFIER" "$METADATA_PLIST"
  plutil -insert executable -string "$EXECUTABLE_NAME" "$METADATA_PLIST"
  plutil -insert platform -integer "$EXPECTED_PLATFORM" "$METADATA_PLIST"
  plutil -insert minimum_os -string "$MACHO_MINIMUM" "$METADATA_PLIST"
  plutil -insert sdk -string "$MACHO_SDK" "$METADATA_PLIST"
  plutil -insert supported_platform -string "$SUPPORTED_PLATFORM" "$METADATA_PLIST"
  plutil -insert signature -string "$SIGNATURE" "$METADATA_PLIST"
  plutil -insert primary_icon -string "$PRIMARY_ICON" "$METADATA_PLIST"
  plutil -insert resource_count -integer "$RESOURCE_COUNT" "$METADATA_PLIST"
  plutil -convert json -o "$METADATA_JSON" "$METADATA_PLIST"
  mv "$METADATA_JSON" "$METADATA"
  rm -f "$METADATA_PLIST"
fi

print "verified arm64 visionOS tabletop $TARGET bundle: $APP"
print "  platform: $EXPECTED_PLATFORM; minimum: $MACHO_MINIMUM; SDK: $MACHO_SDK"
print "  scene:    SwiftUI App/Scene lifecycle; ImmersiveSpace board"
print "  signing:  $SIGNATURE"
print "  content:  compiled resources present; prohibited content absent"
