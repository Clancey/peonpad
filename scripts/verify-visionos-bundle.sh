#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  print "Usage: ./scripts/verify-visionos-bundle.sh <xrsimulator|xros> <app> [--metadata PATH]"
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
EXPECTED_BUNDLE_IDENTIFIER=${PEONPAD_VISIONOS_BUNDLE_IDENTIFIER:-org.peonpad.visionos}
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

[[ -d "$APP" && -f "$APP/Info.plist" ]] || {
  print -u2 "missing visionOS application bundle: $APP"
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
    print -u2 "missing visionOS metadata: $description"
    exit 1
  }
  [[ "$actual" == "$expected" ]] || {
    print -u2 "unexpected visionOS metadata: $description"
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
  print -u2 "unexpected visionOS bundle identifier"
  exit 1
}
[[ -n "$EXECUTABLE_NAME" && "$EXECUTABLE_NAME" != */* ]] || {
  print -u2 "invalid visionOS bundle executable"
  exit 1
}
[[ -n "$PRIMARY_ICON" ]] || {
  print -u2 "visionOS primary icon metadata is missing"
  exit 1
}
version_at_least "$PLIST_MINIMUM" "$MINIMUM_FLOOR" || {
  print -u2 "visionOS Info.plist minimum OS is below $MINIMUM_FLOOR"
  exit 1
}
require_value UIDeviceFamily.0 7 "UIDeviceFamily"
[[ "$(value UIDeviceFamily)" == "1" ]] || {
  print -u2 "visionOS bundle must declare only UIDeviceFamily 7"
  exit 1
}
[[ "$SUPPORTED_PLATFORM" == "$EXPECTED_SUPPORTED_PLATFORM" ]] || {
  print -u2 "unexpected visionOS supported platform"
  exit 1
}
[[ "$(value CFBundleSupportedPlatforms)" == "1" ]] || {
  print -u2 "visionOS bundle contains an unexpected additional platform"
  exit 1
}
require_value UIApplicationPreferredDefaultSceneSessionRole \
  UIWindowSceneSessionRoleApplication "default scene role"
require_value UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes \
  false "multiple-scene policy"
require_value \
  UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneClassName \
  UIWindowScene "window scene class"
require_value \
  UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneDelegateClassName \
  SDLUIKitSceneDelegate "SDL3 scene delegate"
require_value UIApplicationSupportsIndirectInputEvents true \
  "indirect input support"

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

EXECUTABLE="$APP/$EXECUTABLE_NAME"
[[ -x "$EXECUTABLE" ]] || {
  print -u2 "missing visionOS executable: $EXECUTABLE"
  exit 1
}
[[ "$(lipo -archs "$EXECUTABLE")" == "arm64" ]] || {
  print -u2 "visionOS executable is not arm64"
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
  print -u2 "visionOS executable has the wrong platform, minimum OS, or SDK"
  exit 1
}
MACHO_MINIMUM=$(print -r -- "$LOAD_COMMANDS" |
  awk '$1 == "minos" {print $2; exit}')
MACHO_SDK=$(print -r -- "$LOAD_COMMANDS" |
  awk '$1 == "sdk" {print $2; exit}')

[[ -s "$APP/Assets.car" ]] || {
  print -u2 "compiled visionOS icon/resource catalog is missing"
  exit 1
}

FRAMEWORK_COUNT=0
if [[ -d "$APP/Frameworks" ]]; then
  while IFS= read -r -d '' framework_binary; do
    (( FRAMEWORK_COUNT += 1 ))
    [[ "$(lipo -archs "$framework_binary")" == "arm64" ]] || {
      print -u2 "embedded visionOS framework is not arm64"
      exit 1
    }
    otool -l "$framework_binary" | awk \
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
        incomplete = platform_count == 0 || minimum_count == 0 || sdk_count == 0
        exit incomplete || bad
      }
    ' || {
      print -u2 "embedded framework has invalid visionOS load metadata"
      exit 1
    }
  done < <(find "$APP/Frameworks" -type f -perm -111 -print0)
fi

while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    @rpath/*)
      relative_dependency=${dependency#@rpath/}
      case "/$relative_dependency/" in
        */../*)
          print -u2 "embedded visionOS dependency contains parent traversal"
          exit 1
          ;;
      esac
      [[ -f "$APP/Frameworks/$relative_dependency" ]] || {
        print -u2 "missing embedded visionOS dependency: $relative_dependency"
        exit 1
      }
      ;;
    *)
      print -u2 "unexpected visionOS linkage: $dependency"
      exit 1
      ;;
  esac
done < <(otool -L "$EXECUTABLE" |
  awk 'NR > 1 {print $1}')
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
  [[ "$rpath" != *"/../"* && "$rpath" != */.. ]] || {
   print -u2 "unsafe parent traversal in visionOS runtime path"
   exit 1
  }
done <<< "$RPATHS"

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
   print -u2 "visionOS Simulator bundle signature verification failed"
   exit 1
  }
  SIGNATURE_DETAILS=$(codesign -dvv "$APP" 2>&1)
  print -r -- "$SIGNATURE_DETAILS" | grep -q '^Signature=adhoc$' || {
   print -u2 "visionOS Simulator bundle is not ad-hoc signed"
   exit 1
  }
  SIGNATURE=adhoc
else
  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
   print -u2 "xros command-line bundle was unexpectedly signed"
   exit 1
  fi
  SIGNING_ARTIFACT=$(find "$APP" \
   \( -type d -name _CodeSignature \
   -o -type f \( -name CodeResources \
   -o -name embedded.mobileprovision \) \) -print -quit)
  [[ -z "$SIGNING_ARTIFACT" ]] || {
   print -u2 "xros command-line bundle contains signing artifacts"
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
  plutil -insert framework_count -integer "$FRAMEWORK_COUNT" "$METADATA_PLIST"
  plutil -convert json -o "$METADATA_JSON" "$METADATA_PLIST"
  mv "$METADATA_JSON" "$METADATA"
  rm -f "$METADATA_PLIST"
fi

print "verified arm64 visionOS $TARGET bundle: $APP"
print "  platform: $EXPECTED_PLATFORM; minimum: $MACHO_MINIMUM; SDK: $MACHO_SDK"
print "  scene:    SDLUIKitSceneDelegate / resizable UIWindowScene"
print "  signing:  $SIGNATURE"
print "  content:  compiled resources present; prohibited content absent"
