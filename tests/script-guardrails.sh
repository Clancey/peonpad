#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_RUNTIME="$ROOT_DIR/build/test-runtime"
MODE=public

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--maintainer" ]]; }; then
  print -u2 "Usage: ./tests/script-guardrails.sh [--maintainer]"
  exit 2
fi
if (( $# == 1 )); then
  MODE=maintainer
fi

START_DIGEST=""
if [[ "$MODE" == maintainer ]]; then
  EXPECTED_DIGEST=$(awk -F ' *= *' \
    '$1 == "tree_sha256" {gsub(/"/, "", $2); print $2; exit}' \
    "$ROOT_DIR/config/inputs.lock")
  START_DIGEST=$($ROOT_DIR/scripts/reference-digest.sh)
  [[ "$START_DIGEST" == "$EXPECTED_DIGEST" ]] || {
    print -u2 "reference digest does not match the input lock"
    exit 1
  }

  if "$ROOT_DIR/scripts/audit-aleona-assets.sh" --strict >/dev/null 2>&1; then
    print -u2 "strict Aleona distribution audit unexpectedly passed"
    exit 1
  fi
  "$ROOT_DIR/scripts/audit-aleona-assets.sh" --local-test >/dev/null
fi

"$ROOT_DIR/scripts/prepare-ipad-build.sh" --help >/dev/null
"$ROOT_DIR/scripts/preflight-vision-compat.sh" --help >/dev/null
"$ROOT_DIR/scripts/build-vision-compat-simulator.sh" --help >/dev/null
"$ROOT_DIR/scripts/build-sdl3-foundation.sh" --help >/dev/null
"$ROOT_DIR/scripts/build-visionos-shell.sh" --help >/dev/null
"$ROOT_DIR/scripts/accept-visionos.sh" --help >/dev/null
"$ROOT_DIR/scripts/verify-visionos-bundle.sh" --help >/dev/null
"$ROOT_DIR/scripts/install-visionos-device.sh" --help >/dev/null
"$ROOT_DIR/scripts/verify-sdl3-sources.sh" >/dev/null
"$ROOT_DIR/scripts/build-visionos-tabletop.sh" --help >/dev/null
"$ROOT_DIR/scripts/verify-tabletop-bundle.sh" --help >/dev/null
"$ROOT_DIR/scripts/test-visionos-tabletop-gestures.sh" --help >/dev/null
rg -q 'PEONPAD_IOS_CONTROL_DOCK=ON' \
  "$ROOT_DIR/scripts/build-vision-compat-simulator.sh"
rg -q 'PEONPAD_IOS_CONTROL_DOCK.*OFF' \
  "$ROOT_DIR/scripts/generate-ios-xcode.sh"
rg -q 'indirectPointerMoving:touch' \
  "$ROOT_DIR/engine/stratagus/third-party/SDL/src/video/uikit/SDL_uikitview.m"
IOS_DATA_STAGE_SCRIPT="$ROOT_DIR/scripts/stage-ios-wc2-test-data.sh"
rg -Fq -- "--exclude '*.[Mm][Pp][Qq]'" "$IOS_DATA_STAGE_SCRIPT"
rg -Fq -- \
  "--exclude '[Ii][Nn][Ss][Tt][Aa][Ll][Ll].[Ee][Xx][Ee]'" \
  "$IOS_DATA_STAGE_SCRIPT"
if "$ROOT_DIR/scripts/prepare-ipad-build.sh" --installer missing.exe \
    --data missing-data >/dev/null 2>&1; then
  print -u2 "prepare script accepted multiple input modes"
  exit 1
fi
if "$ROOT_DIR/scripts/build-vision-compat-simulator.sh" \
    --unsupported >/dev/null 2>&1; then
  print -u2 "Vision compatibility build accepted an unsupported option"
  exit 1
fi
if "$ROOT_DIR/scripts/build-sdl3-foundation.sh" \
    unsupported >/dev/null 2>&1; then
  print -u2 "SDL3 foundation build accepted an unsupported target"
  exit 1
fi
if "$ROOT_DIR/scripts/build-visionos-shell.sh" \
    unsupported >/dev/null 2>&1; then
  print -u2 "visionOS shell build accepted an unsupported target"
  exit 1
fi

VISION_TOOLCHAIN="$ROOT_DIR/cmake/toolchains/ios-simulator-arm64.cmake"
rg -q 'CMAKE_OSX_SYSROOT iphonesimulator' "$VISION_TOOLCHAIN"
rg -q 'SUPPORTED_PLATFORMS' "$VISION_TOOLCHAIN"
rg -q 'SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD YES' "$VISION_TOOLCHAIN"

XROS_TOOLCHAIN="$ROOT_DIR/cmake/toolchains/xros-simulator-arm64.cmake"
rg -q 'CMAKE_SYSTEM_NAME visionOS' "$XROS_TOOLCHAIN"
rg -q 'CMAKE_OSX_SYSROOT xrsimulator' "$XROS_TOOLCHAIN"
rg -q 'PEONPAD_VISIONOS_SIMULATOR_BUILD TRUE' "$XROS_TOOLCHAIN"
rg -q 'CMAKE_VERSION VERSION_LESS "3\.28"' "$XROS_TOOLCHAIN"
XROS_DEVICE_TOOLCHAIN="$ROOT_DIR/cmake/toolchains/xros-arm64.cmake"
rg -q 'CMAKE_SYSTEM_NAME visionOS' "$XROS_DEVICE_TOOLCHAIN"
rg -q 'CMAKE_OSX_SYSROOT xros' "$XROS_DEVICE_TOOLCHAIN"
rg -q 'PEONPAD_VISIONOS_DEVICE_BUILD TRUE' "$XROS_DEVICE_TOOLCHAIN"
rg -q 'CMAKE_VERSION VERSION_LESS "3\.28"' "$XROS_DEVICE_TOOLCHAIN"
rg -q '^cmake_minimum_required\(VERSION 3\.27\)' "$ROOT_DIR/CMakeLists.txt"
rg -q 'CMAKE_SYSTEM_NAME STREQUAL "visionOS".*' "$ROOT_DIR/CMakeLists.txt"
rg -q 'CMAKE_VERSION VERSION_LESS "3\.28"' "$ROOT_DIR/CMakeLists.txt"
rg -q 'PEONPAD_EXPECT_VISIONOS=1' "$ROOT_DIR/CMakeLists.txt"
rg -q 'PEONPAD_VISIONOS.*TARGET_OS_VISION.*TARGET_OS_IOS.*TARGET_OS_OSX' \
  "$ROOT_DIR/tests/toolchain_probe.cpp"

SDL3_BUILD_SCRIPT="$ROOT_DIR/scripts/build-sdl3-foundation.sh"
rg -q 'cmake --build "\$BUILD_DIR" --parallel' "$SDL3_BUILD_SCRIPT"
if rg -q -- '--target peonpad_sdl3_smoke' "$SDL3_BUILD_SCRIPT"; then
  print -u2 "SDL3 foundation validation builds only the smoke target"
  exit 1
fi
VISIONOS_BUILD_SCRIPT="$ROOT_DIR/scripts/build-visionos-shell.sh"
rg -q 'cmake --build "\$BUILD_DIR" --parallel' "$VISIONOS_BUILD_SCRIPT"
if rg -q -- '--target peonpad_sdl3_smoke' "$VISIONOS_BUILD_SCRIPT"; then
  print -u2 "visionOS shell validation builds only the smoke target"
  exit 1
fi
rg -q 'find-vision-pro-simulator\.sh' "$VISIONOS_BUILD_SCRIPT"
rg -q 'simctl bootstatus' "$VISIONOS_BUILD_SCRIPT"
rg -q 'simctl install' "$VISIONOS_BUILD_SCRIPT"
rg -q 'simctl launch --terminate-running-process' "$VISIONOS_BUILD_SCRIPT"
rg -q 'launchctl procinfo' "$VISIONOS_BUILD_SCRIPT"
rg -q 'native visionOS builds require CMake 3\.28' "$VISIONOS_BUILD_SCRIPT"
VISIONOS_ACCEPTANCE_SCRIPT="$ROOT_DIR/scripts/accept-visionos.sh"
rg -q 'build-visionos-shell\.sh' "$VISIONOS_ACCEPTANCE_SCRIPT"
rg -q 'verify-visionos-bundle\.sh' "$VISIONOS_ACCEPTANCE_SCRIPT"
rg -q 'simctl launch --terminate-running-process' \
  "$VISIONOS_ACCEPTANCE_SCRIPT"
rg -q 'launchctl procinfo' "$VISIONOS_ACCEPTANCE_SCRIPT"
rg -q 'simctl uninstall' "$VISIONOS_ACCEPTANCE_SCRIPT"
rg -q 'plutil -convert json' "$VISIONOS_ACCEPTANCE_SCRIPT"
rg -Fq 'PEONPAD_VISIONOS_READY=1' "$VISIONOS_ACCEPTANCE_SCRIPT"
rg -Fq 'PEONPAD_VISIONOS_READY=1' \
  "$ROOT_DIR/tests/sdl3_foundation_smoke.cpp"
rg -q 'assetutil --info' \
  "$ROOT_DIR/scripts/verify-visionos-bundle.sh"
if rg -q -- '--target peonpad_sdl3_smoke' "$VISIONOS_ACCEPTANCE_SCRIPT"; then
  print -u2 "visionOS acceptance builds only the smoke target"
  exit 1
fi
if rg -q 'SMOKE SHELL|NO GAMEPLAY' "$VISIONOS_ACCEPTANCE_SCRIPT"; then
  print -u2 "generic visionOS acceptance contains a smoke-only assertion"
  exit 1
fi
rg -q 'PEONPAD_VISIONOS_DEVICE_INSTALL' \
  "$ROOT_DIR/scripts/install-visionos-device.sh"
rg -q 'native visionOS configuration \(3\.28\+\)' \
  "$ROOT_DIR/scripts/preflight.sh"

CMAKE_GUARD_ROOT="$TEST_RUNTIME/cmake-version"
CMAKE_GUARD_BIN="$CMAKE_GUARD_ROOT/bin"
cmake -E remove_directory "$CMAKE_GUARD_ROOT"
cmake -E make_directory "$CMAKE_GUARD_BIN"
cp "$ROOT_DIR/tests/fixtures/fake-cmake-3.27.sh" \
  "$CMAKE_GUARD_BIN/cmake"
chmod +x "$CMAKE_GUARD_BIN/cmake"
if PATH="$CMAKE_GUARD_BIN:$PATH" \
    "$ROOT_DIR/scripts/build-visionos-shell.sh" xrsimulator \
      >/dev/null 2>&1; then
  print -u2 "native visionOS build accepted CMake 3.27"
  exit 1
fi
cmake -E remove_directory "$CMAKE_GUARD_ROOT"

rg -q 'option\(PEONPAD_ENABLE_SDL3' "$ROOT_DIR/CMakeLists.txt"
rg -q 'SDL-release-3\.4\.12\.tar\.gz' "$ROOT_DIR/config/inputs.lock"
rg -q 'SDL_image-release-3\.4\.4\.tar\.gz' "$ROOT_DIR/config/inputs.lock"
rg -q 'SDL_mixer-release-3\.2\.4\.tar\.gz' "$ROOT_DIR/config/inputs.lock"
if find "$ROOT_DIR/third_party/sdl3" -iname '*sdl2-compat*' -print -quit \
    | grep -q .; then
  print -u2 "sdl2-compat entered the direct SDL3 dependency tree"
  exit 1
fi
if rg -q 'SDL_syswm' "$ROOT_DIR/platform/apple/visionos"; then
  print -u2 "legacy SDL_syswm entered the native visionOS shell"
  exit 1
fi

VISION_PLIST="$ROOT_DIR/platform/apple/visionos/Info.plist.in"
plutil -lint "$VISION_PLIST" >/dev/null
[[ "$(plutil -extract UIDeviceFamily.0 raw "$VISION_PLIST")" == "7" ]]
[[ "$(plutil -extract \
  UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneDelegateClassName \
  raw "$VISION_PLIST")" == "SDLUIKitSceneDelegate" ]]
for forbidden_key in \
  'CFBundleIcons~ipad' \
  UIRequiresFullScreen \
  'UISupportedInterfaceOrientations~ipad'; do
  if plutil -extract "$forbidden_key" raw "$VISION_PLIST" \
      >/dev/null 2>&1; then
    print -u2 "iPad-only key entered visionOS metadata: $forbidden_key"
    exit 1
  fi
done

rg -q 'MACOSX_PACKAGE_LOCATION Resources' \
  "$ROOT_DIR/cmake/PeonPadSDL3.cmake"

VISION_ASSET_ROOT="$TEST_RUNTIME/visionos-assets"
VISION_ASSET_APP="$VISION_ASSET_ROOT/PeonPadVisionShell.app"
cmake -E remove_directory "$VISION_ASSET_ROOT"
cmake -E make_directory "$VISION_ASSET_APP"
"$ROOT_DIR/platform/apple/visionos/compile-bundle-assets.sh" \
  xrsimulator "$(command -v cmake)" "$VISION_ASSET_APP" \
  "$ROOT_DIR/platform/apple/visionos/PeonPadAssets.xcassets" \
  "$ROOT_DIR/platform/apple/ios/PeonPadAssets.xcassets/AppIcon.appiconset/PeonPadIcon.png" \
  "$VISION_ASSET_ROOT/work" >/dev/null
[[ -f "$VISION_ASSET_APP/Assets.car" ]]
[[ "$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon raw \
  "$VISION_ASSET_ROOT/work/asset-info.plist")" == "AppIcon" ]]
cmake -E remove_directory "$VISION_ASSET_ROOT"
rg -q -- '-DNDEBUG' "$ROOT_DIR/scripts/test-ios-viewport.sh"
if rg -q '\bassert\(' "$ROOT_DIR/tests/viewport_geometry_test.cpp"; then
  print -u2 "Release viewport/input checks rely on assert"
  exit 1
fi
rg -q 'SDL_GetWindowSafeArea' "$ROOT_DIR/tests/sdl3_foundation_smoke.cpp"
rg -q 'SDL_EVENT_WINDOW_SAFE_AREA_CHANGED' \
  "$ROOT_DIR/tests/sdl3_foundation_smoke.cpp"
rg -q 'SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED' \
  "$ROOT_DIR/tests/sdl3_foundation_smoke.cpp"

SIMCTL_TEST_ROOT="$TEST_RUNTIME/simctl"
SIMCTL_TEST_BIN="$SIMCTL_TEST_ROOT/bin"
SIMCTL_TEST_DEVICES="$SIMCTL_TEST_ROOT/devices.txt"
VISION_UDID=11111111-1111-1111-1111-111111111111
IPAD_UDID=22222222-2222-2222-2222-222222222222
cmake -E remove_directory "$SIMCTL_TEST_ROOT"
cmake -E make_directory "$SIMCTL_TEST_BIN"
cp "$ROOT_DIR/tests/fixtures/fake-xcrun.sh" "$SIMCTL_TEST_BIN/xcrun"
chmod +x "$SIMCTL_TEST_BIN/xcrun"
print -r -- "-- iOS 26.5 --
    iPad Pro 13-inch (M5) ($IPAD_UDID) (Shutdown)
-- visionOS 26.5 --
    Apple Vision Pro ($VISION_UDID) (Shutdown)" > "$SIMCTL_TEST_DEVICES"

SELECTED_VISION_UDID=$(
  PATH="$SIMCTL_TEST_BIN:$PATH" \
  PEONPAD_TEST_SIMCTL_DEVICES_FILE="$SIMCTL_TEST_DEVICES" \
  PEONPAD_VISION_SIMULATOR_UDID="$VISION_UDID" \
    "$ROOT_DIR/scripts/find-vision-pro-simulator.sh"
)
[[ "$SELECTED_VISION_UDID" == "$VISION_UDID" ]] || {
  print -u2 "Vision Pro simulator override selected the wrong device"
  exit 1
}
if PATH="$SIMCTL_TEST_BIN:$PATH" \
    PEONPAD_TEST_SIMCTL_DEVICES_FILE="$SIMCTL_TEST_DEVICES" \
    PEONPAD_VISION_SIMULATOR_UDID="$IPAD_UDID" \
      "$ROOT_DIR/scripts/find-vision-pro-simulator.sh" >/dev/null 2>&1; then
  print -u2 "Vision Pro simulator override accepted an iPad simulator"
  exit 1
fi
cmake -E remove_directory "$SIMCTL_TEST_ROOT"

"$ROOT_DIR/tests/visionos-acceptance.sh"

# Native visionOS tabletop foundation: pure-logic gesture/board-manipulation/
# directional-billboard-frame tests (fast, host-only, no Simulator needed),
# plus static guardrails that the tabletop app stays fully separate from the
# SDL3 smoke shell (distinct bundle id, distinct scene lifecycle, distinct
# executable) and carries no proprietary Warcraft II data.
"$ROOT_DIR/scripts/test-visionos-tabletop-gestures.sh" >/dev/null

# Tabletop gameplay slice: pure-logic snapshot model, command reducer, and
# defect regressions (dead-unit validation, two-hand suppression). Runs on
# the host Mac; no Simulator needed.
"$ROOT_DIR/scripts/test-visionos-tabletop-gameplay.sh" --help >/dev/null
"$ROOT_DIR/scripts/test-visionos-tabletop-gameplay.sh" >/dev/null
if rg -Fq 'assert(' \
    "$ROOT_DIR/tests/tabletop_gameplay_state_test.swift"; then
  print -u2 "tabletop gameplay tests rely on Swift assert instead of" \
    "always-on checks"
  exit 1
fi

TABLETOP_PLIST="$ROOT_DIR/platform/apple/visionos/tabletop/Info.plist.in"
plutil -lint "$TABLETOP_PLIST" >/dev/null
[[ "$(plutil -extract UIDeviceFamily.0 raw "$TABLETOP_PLIST")" == "7" ]]
[[ "$(plutil -extract CFBundleExecutable raw "$TABLETOP_PLIST")" == \
    "PeonPadTabletop" ]]
if plutil -extract \
    UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneDelegateClassName \
    raw "$TABLETOP_PLIST" >/dev/null 2>&1; then
  print -u2 "tabletop app must not declare the SDL3 scene delegate"
  exit 1
fi
for forbidden_key in \
  'CFBundleIcons~ipad' \
  UIRequiresFullScreen \
  'UISupportedInterfaceOrientations~ipad'; do
  if plutil -extract "$forbidden_key" raw "$TABLETOP_PLIST" \
      >/dev/null 2>&1; then
    print -u2 "iPad-only key entered visionOS tabletop metadata: $forbidden_key"
    exit 1
  fi
done
rg -q '@PEONPAD_TABLETOP_BUNDLE_IDENTIFIER@' "$TABLETOP_PLIST"
rg -q 'org\.peonpad\.visionos\.tabletop' \
  "$ROOT_DIR/scripts/build-visionos-tabletop.sh" \
  "$ROOT_DIR/scripts/verify-tabletop-bundle.sh"
rg -Fq 'bundle identifier collides with the smoke shell' \
  "$ROOT_DIR/scripts/verify-tabletop-bundle.sh"
if rg -q 'SDLUIKitSceneDelegate' \
    "$ROOT_DIR/platform/apple/visionos/tabletop"/*.swift \
    "$ROOT_DIR/platform/apple/visionos/tabletop/Info.plist.in" \
    2>/dev/null; then
  print -u2 "the SDL3 scene delegate leaked into the tabletop app"
  exit 1
fi
if rg -Fq -- '-DCMAKE_TOOLCHAIN_FILE' \
    "$ROOT_DIR/scripts/build-visionos-tabletop.sh"; then
  print -u2 "the tabletop build script must stay independent of CMake"
  exit 1
fi
if rg -Fq 'assert(' \
    "$ROOT_DIR/tests/tabletop_gesture_state_test.swift"; then
  print -u2 "tabletop pure-logic tests rely on Swift assert instead of" \
    "always-on checks"
  exit 1
fi

IOS_PLIST="$ROOT_DIR/platform/apple/ios/Info.plist.in"
plutil -lint "$IOS_PLIST" >/dev/null
[[ "$(plutil -extract UILaunchScreen.UIImageName raw "$IOS_PLIST")" == \
    "PeonPadLaunch" ]]
[[ "$(plutil -extract 'CFBundleIcons~ipad'.CFBundlePrimaryIcon.CFBundleIconFiles.0 raw \
    "$IOS_PLIST")" == "PeonPadIcon76" ]]

verify_png() {
  local file=$1 expected_width=$2 expected_height=$3
  local properties width height alpha
  properties=$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$file")
  width=$(awk '$1 == "pixelWidth:" {print $2}' <<< "$properties")
  height=$(awk '$1 == "pixelHeight:" {print $2}' <<< "$properties")
  alpha=$(awk '$1 == "hasAlpha:" {print $2}' <<< "$properties")
  [[ "$width" == "$expected_width" && "$height" == "$expected_height" \
      && "$alpha" == "no" ]] || {
    print -u2 "invalid opaque iOS artwork: $file"
    exit 1
  }
}

verify_png "$ROOT_DIR/platform/apple/ios/PeonPadLaunch.png" 1024 1024
verify_png "$ROOT_DIR/platform/apple/ios/PeonPadIcon76.png" 76 76
verify_png "$ROOT_DIR/platform/apple/ios/PeonPadIcon76@2x.png" 152 152
verify_png "$ROOT_DIR/platform/apple/ios/PeonPadIcon83.5@2x.png" 167 167

RESOURCE_TEST_ROOT="$TEST_RUNTIME/xcode-resource-copy"
RESOURCE_DATA="$RESOURCE_TEST_ROOT/source-data"
RESOURCE_PRODUCTS="$RESOURCE_TEST_ROOT/products/Release-iphoneos"
cmake -E remove_directory "$RESOURCE_TEST_ROOT"
cmake -E make_directory "$RESOURCE_DATA/scripts"
cmake -E touch "$RESOURCE_DATA/scripts/stratagus.lua"
TARGET_BUILD_DIR="$RESOURCE_PRODUCTS" WRAPPER_NAME="PeonPad.app" \
  "$ROOT_DIR/platform/apple/ios/copy-xcode-bundle-resources.sh" \
  "$(command -v cmake)" "$RESOURCE_DATA" \
  "$ROOT_DIR/platform/apple/ios/PeonPadLaunch.png" \
  "$ROOT_DIR/platform/apple/ios"
RESOURCE_APP="$RESOURCE_PRODUCTS/PeonPad.app"
[[ -f "$RESOURCE_APP/Aleona/scripts/stratagus.lua" ]]
cmp -s "$ROOT_DIR/platform/apple/ios/PeonPadLaunch.png" \
  "$RESOURCE_APP/PeonPadLaunch.png"
cmp -s "$ROOT_DIR/platform/apple/ios/PeonPadIcon83.5@2x.png" \
  "$RESOURCE_APP/PeonPadIcon83.5@2x.png"
cmake -E remove_directory "$RESOURCE_TEST_ROOT"

if [[ "$MODE" == maintainer ]]; then
  if "$ROOT_DIR/scripts/run-macos.sh" \
      --binary "$ROOT_DIR/ref/Wargus.app/Contents/MacOS/stratagus" \
      --profile wc2 -- -h >/dev/null 2>&1; then
    print -u2 "runtime wrapper accepted a forbidden reference executable"
    exit 1
  fi
fi

FAKE_DATA="$TEST_RUNTIME/fake-data.Wargus"
cmake -E make_directory "$FAKE_DATA"
PEONPAD_RUNTIME_ROOT="$TEST_RUNTIME" \
  "$ROOT_DIR/scripts/run-macos.sh" \
    --binary "$ROOT_DIR/tests/fixtures/fake-stratagus.sh" \
    --profile wc2 --data "$FAKE_DATA" -- -W >/dev/null

OBSERVATION="$TEST_RUNTIME/wc2/user/fake-engine-observation.txt"
[[ -f "$OBSERVATION" ]] || {
  print -u2 "fake engine did not write to the isolated user path"
  exit 1
}

rg -q "^data=$FAKE_DATA$" "$OBSERVATION"
rg -q "^user=$TEST_RUNTIME/wc2/user$" "$OBSERVATION"
rg -q "^home=$TEST_RUNTIME/wc2/home$" "$OBSERVATION"
rg -q "^cache=$TEST_RUNTIME/wc2/cache$" "$OBSERVATION"
rg -q "^tmp=$TEST_RUNTIME/wc2/tmp$" "$OBSERVATION"

PATCH_CHAIN_ROOT="$TEST_RUNTIME/patch-chain"
PATCH_CHAIN_ENGINE="$PATCH_CHAIN_ROOT/stratagus"
cmake -E remove_directory "$PATCH_CHAIN_ROOT"
cmake -E make_directory "$PATCH_CHAIN_ROOT"
cp -cR "$ROOT_DIR/engine/stratagus" "$PATCH_CHAIN_ENGINE"

# The patches form an ordered series, so validate composition by reversing the
# complete staged series and then applying it again in the stage-script order.
for patch_file in \
  0012-tabletop-bridge-gamehook.patch \
  0011-visionos-indirect-controls.patch \
  0010-direct-sdl3-engine.patch \
  0009-game-controller-input.patch \
  0008-input-intent-router.patch \
  0007-build-host-toluapp.patch \
  0006-ios-launch-image-resource.patch \
  0005-ios-metal-safe-area-viewport.patch \
  0004-ios-xcode-external-generator.patch \
  0003-ios-arm64-static-dependencies.patch \
  0002-route-relative-editor-maps-to-user.patch \
  0001-xcode-26-apple-vendored-deps.patch; do
  patch --no-backup-if-mismatch -R -s -d "$PATCH_CHAIN_ENGINE" -p1 \
    < "$ROOT_DIR/patches/stratagus/$patch_file"
done
for patch_file in \
  0001-xcode-26-apple-vendored-deps.patch \
  0002-route-relative-editor-maps-to-user.patch \
  0003-ios-arm64-static-dependencies.patch \
  0004-ios-xcode-external-generator.patch \
  0005-ios-metal-safe-area-viewport.patch \
  0006-ios-launch-image-resource.patch; do
  patch --no-backup-if-mismatch -s -d "$PATCH_CHAIN_ENGINE" -p1 \
    < "$ROOT_DIR/patches/stratagus/$patch_file"
done
patch --no-backup-if-mismatch -s -d "$PATCH_CHAIN_ENGINE" -p1 \
  < "$ROOT_DIR/patches/stratagus/0007-build-host-toluapp.patch"
patch --no-backup-if-mismatch -s -d "$PATCH_CHAIN_ENGINE" -p1 \
  < "$ROOT_DIR/patches/stratagus/0008-input-intent-router.patch"
patch --no-backup-if-mismatch -s -d "$PATCH_CHAIN_ENGINE" -p1 \
  < "$ROOT_DIR/patches/stratagus/0009-game-controller-input.patch"
patch --no-backup-if-mismatch -s -d "$PATCH_CHAIN_ENGINE" -p1 \
  < "$ROOT_DIR/patches/stratagus/0010-direct-sdl3-engine.patch"
patch --no-backup-if-mismatch -s -d "$PATCH_CHAIN_ENGINE" -p1 \
  < "$ROOT_DIR/patches/stratagus/0011-visionos-indirect-controls.patch"
patch --no-backup-if-mismatch -s -d "$PATCH_CHAIN_ENGINE" -p1 \
  < "$ROOT_DIR/patches/stratagus/0012-tabletop-bridge-gamehook.patch"
diff --no-dereference -qr \
  "$ROOT_DIR/engine/stratagus" "$PATCH_CHAIN_ENGINE" >/dev/null
EXPECTED_STRATAGUS_TREE_SHA=$(awk -F ' *= *' '
  $0 == "[sources.stratagus]" {in_section = 1; next}
  /^\[/ {in_section = 0}
  in_section && $1 == "staged_tree_sha256" {
    gsub(/"/, "", $2)
    print $2
    exit
  }
' "$ROOT_DIR/config/inputs.lock")
ACTUAL_STRATAGUS_TREE_SHA=$(
  "$ROOT_DIR/scripts/tracked-tree-sha256.sh" "$ROOT_DIR/engine/stratagus"
)
[[ "$ACTUAL_STRATAGUS_TREE_SHA" == "$EXPECTED_STRATAGUS_TREE_SHA" ]] || {
  print -u2 "reconstructed Stratagus tree digest does not match the input lock"
  exit 1
}
cmake -E remove_directory "$PATCH_CHAIN_ROOT"
if [[ "$MODE" == maintainer ]]; then
  patch --dry-run -s -d "$ROOT_DIR/ref/wargus" -p1 \
    < "$ROOT_DIR/patches/wargus/0001-xcode-26-apple-vendored-deps.patch"
  patch --dry-run -s -d "$ROOT_DIR/ref/wargus" -p1 \
    < "$ROOT_DIR/patches/wargus/0002-ios-data-layer-library.patch"

  END_DIGEST=$($ROOT_DIR/scripts/reference-digest.sh)
  [[ "$END_DIGEST" == "$START_DIGEST" ]] || {
    print -u2 "reference material changed during script guardrail tests"
    exit 1
  }
fi

# Tabletop bridge: verify the ABI header and engine hook exist and are
# structurally consistent (no proprietary assets; pure C interface).
BRIDGE_HEADER="$ROOT_DIR/platform/bridge/PeonPadTabletopBridge.h"
BRIDGE_IMPL="$ROOT_DIR/platform/bridge/PeonPadTabletopBridge.cpp"
BRIDGE_PATCH="$ROOT_DIR/patches/stratagus/0012-tabletop-bridge-gamehook.patch"
[[ -f "$BRIDGE_HEADER" ]] || { print -u2 "bridge header missing"; exit 1; }
[[ -f "$BRIDGE_IMPL" ]]   || { print -u2 "bridge impl missing"; exit 1; }
[[ -f "$BRIDGE_PATCH" ]]  || { print -u2 "bridge patch missing"; exit 1; }
rg -q 'PEONPAD_TABLETOP_ABI_VERSION' "$BRIDGE_HEADER"
rg -q 'PeonPadSnapshot' "$BRIDGE_HEADER"
rg -q 'PeonPadTerrainCell' "$BRIDGE_HEADER"
rg -q 'PeonPadUnitRecord' "$BRIDGE_HEADER"
rg -q 'PeonPadCommand' "$BRIDGE_HEADER"
rg -q 'peonpad_tabletop_publish_synthetic' "$BRIDGE_HEADER"
rg -q 'extern "C"' "$BRIDGE_HEADER"
# The bridge header must not include any C++ or SDL or Stratagus headers.
if rg -q '#include <SDL|#include "SDL|#include "stratagus|#include "unit' \
    "$BRIDGE_HEADER"; then
  print -u2 "bridge public header contains engine or SDL includes"
  exit 1
fi
# The game loop hook must guard with PEONPAD_TABLETOP.
rg -q 'PEONPAD_TABLETOP' "$BRIDGE_PATCH"
rg -q 'peonpad_tabletop_publish_snapshot' "$BRIDGE_PATCH"
rg -q 'peonpad_tabletop_drain_commands' "$BRIDGE_PATCH"
# The Clang module map must be present alongside the header.
MODULE_MAP="$ROOT_DIR/platform/bridge/module.modulemap"
[[ -f "$MODULE_MAP" ]] || { print -u2 "bridge module.modulemap missing"; exit 1; }
rg -q 'PeonPadTabletopBridge' "$MODULE_MAP"
# Verify no proprietary assets were committed alongside the bridge.
if find "$ROOT_DIR/platform/bridge" -name '*.wav' -o -name '*.mpq' \
    -o -name '*.pud' | grep -q .; then
  print -u2 "proprietary assets found in platform/bridge"
  exit 1
fi

# ── Tabletop transport/lifecycle/data-paths source files ──────────────────────

TABLETOP_SRC="$ROOT_DIR/platform/apple/visionos/tabletop"
for _f in \
    TabletopDataPaths.swift \
    TabletopEngineLifecycle.swift \
    TabletopEngineTransport.swift; do
  [[ -f "$TABLETOP_SRC/$_f" ]] || {
    print -u2 "tabletop transport file missing: $_f"
    exit 1
  }
done
# DataPaths: must reference Documents/wargus-data and Application Support.
rg -q 'wargus-data' "$TABLETOP_SRC/TabletopDataPaths.swift"
rg -q 'applicationSupportDirectory' "$TABLETOP_SRC/TabletopDataPaths.swift"
# Must fail visibly when game data is absent; must not silently use demo state.
rg -q 'gameDataUnavailable' "$TABLETOP_SRC/TabletopDataPaths.swift"

# Lifecycle: must call init/cleanup under #if canImport guard.
rg -q 'canImport(PeonPadTabletopBridge)' "$TABLETOP_SRC/TabletopEngineLifecycle.swift"
rg -q 'peonpad_tabletop_init' "$TABLETOP_SRC/TabletopEngineLifecycle.swift"
rg -q 'peonpad_tabletop_cleanup' "$TABLETOP_SRC/TabletopEngineLifecycle.swift"
# Lifecycle must have explicit state machine states.
rg -q 'initializing' "$TABLETOP_SRC/TabletopEngineLifecycle.swift"
rg -q 'ready' "$TABLETOP_SRC/TabletopEngineLifecycle.swift"
rg -q 'shutdown' "$TABLETOP_SRC/TabletopEngineLifecycle.swift"

# Transport: must bridge all five command types.
rg -q 'PEONPAD_CMD_SELECT' "$TABLETOP_SRC/TabletopEngineTransport.swift"
rg -q 'PEONPAD_CMD_DESELECT_ALL' "$TABLETOP_SRC/TabletopEngineTransport.swift"
rg -q 'PEONPAD_CMD_MOVE' "$TABLETOP_SRC/TabletopEngineTransport.swift"
rg -q 'PEONPAD_CMD_STOP' "$TABLETOP_SRC/TabletopEngineTransport.swift"
# Transport: must validate ABI version before converting.
rg -q 'PEONPAD_TABLETOP_ABI_VERSION' "$TABLETOP_SRC/TabletopEngineTransport.swift"
# Transport: must use retain/release.
rg -q 'peonpad_snapshot_retain' "$TABLETOP_SRC/TabletopEngineTransport.swift"
rg -q 'peonpad_snapshot_release' "$TABLETOP_SRC/TabletopEngineTransport.swift"
# Transport: must have tileZ ↔ tile_y coordinate-mapping comment.
rg -q 'tileZ.*tile_y\|tile_y.*tileZ' "$TABLETOP_SRC/TabletopEngineTransport.swift"
# Transport test script must exist and be executable.
[[ -x "$ROOT_DIR/scripts/test-visionos-tabletop-transport.sh" ]] || {
  print -u2 "test-visionos-tabletop-transport.sh missing or not executable"
  exit 1
}
# Transport: stub for non-bridge builds must exist (no proprietary symbols leaked).
rg -q 'else.*PeonPadTabletopBridge not available\|PeonPadTabletopBridge not available' \
    "$TABLETOP_SRC/TabletopEngineTransport.swift"

# ── visionOS Wargus data staging guardrails ────────────────────────────────────

VISIONOS_STAGE_SCRIPT="$ROOT_DIR/scripts/stage-visionos-wargus-data.sh"
VISIONOS_INJECT_SCRIPT="$ROOT_DIR/scripts/inject-visionos-wargus-data.sh"

# Both scripts must advertise --help without side effects.
"$VISIONOS_STAGE_SCRIPT" --help >/dev/null
"$VISIONOS_INJECT_SCRIPT" --help >/dev/null

# The staging script must exclude proprietary archives and macOS metadata.
rg -Fq -- "--exclude '*.[Mm][Pp][Qq]'" "$VISIONOS_STAGE_SCRIPT"
rg -Fq -- "--exclude '[Ii][Nn][Ss][Tt][Aa][Ll][Ll].[Ee][Xx][Ee]'" \
  "$VISIONOS_STAGE_SCRIPT"
rg -Fq -- "--exclude .DS_Store" "$VISIONOS_STAGE_SCRIPT"

# The staging script must refuse a source inside the repository.
rg -q 'source must be outside the repository' "$VISIONOS_STAGE_SCRIPT"

# The staging script must verify the destination is git-ignored.
rg -q 'git.*check-ignore' "$VISIONOS_STAGE_SCRIPT"

# The inject script must use the data container (not the app bundle).
rg -q 'get_app_container' "$VISIONOS_INJECT_SCRIPT"
rg -Fq -- 'data 2>/dev/null' "$VISIONOS_INJECT_SCRIPT"

# The inject script must reject a missing staged directory with a clear message.
rg -q 'staged game data not found' "$VISIONOS_INJECT_SCRIPT"

# Staging to a missing source must fail with a meaningful error.
WARGUS_STAGE_ROOT="$TEST_RUNTIME/wargus-stage"
cmake -E remove_directory "$WARGUS_STAGE_ROOT"
cmake -E make_directory "$WARGUS_STAGE_ROOT"

if PEONPAD_WARGUS_DATA_DIR="$WARGUS_STAGE_ROOT/nonexistent" \
    "$VISIONOS_STAGE_SCRIPT" >/dev/null 2>&1; then
  print -u2 "staging script accepted a non-existent data directory"
  exit 1
fi

# Staging from an incomplete directory (missing required files) must fail.
FAKE_WARGUS_INCOMPLETE="$WARGUS_STAGE_ROOT/incomplete.Wargus"
cmake -E make_directory "$FAKE_WARGUS_INCOMPLETE"
if PEONPAD_WARGUS_DATA_DIR="$FAKE_WARGUS_INCOMPLETE" \
    "$VISIONOS_STAGE_SCRIPT" >/dev/null 2>&1; then
  print -u2 "staging script accepted a directory missing required wargus files"
  exit 1
fi

# Staging from a valid synthetic directory must succeed and land in build/.
# The source must be outside the repository; use a tmpdir for the fixture.
FAKE_WARGUS=$(mktemp -d "${TMPDIR:-/tmp}/peonpad-fake-wargus.XXXXXX")
STAGED_TEST_DIR="$ROOT_DIR/build/visionos-wargus-data"
STAGED_TEST_BACKUP=""
cleanup_wargus_staging_test() {
  rm -rf "$FAKE_WARGUS"
  cmake -E remove_directory "$STAGED_TEST_DIR"
  if [[ -n "$STAGED_TEST_BACKUP" && -d "$STAGED_TEST_BACKUP" ]]; then
    mv "$STAGED_TEST_BACKUP" "$STAGED_TEST_DIR"
    STAGED_TEST_BACKUP=""
  fi
}
trap cleanup_wargus_staging_test EXIT

# If the developer already has staged real data, preserve it across the test.
if [[ -d "$STAGED_TEST_DIR" ]]; then
  STAGED_TEST_BACKUP=$(mktemp -d "${TMPDIR:-/tmp}/peonpad-staged-backup.XXXXXX")
  cp -R "$STAGED_TEST_DIR/." "$STAGED_TEST_BACKUP/"
fi

cmake -E make_directory "$FAKE_WARGUS/scripts"
cmake -E make_directory "$FAKE_WARGUS/graphics"
cmake -E make_directory "$FAKE_WARGUS/maps"
cmake -E make_directory "$FAKE_WARGUS/sounds"
printf 'AddTrigger("GameStarted")' > "$FAKE_WARGUS/scripts/stratagus.lua"
printf 'extracted' > "$FAKE_WARGUS/extracted"
# Include a fake proprietary archive to confirm it is excluded.
printf '\x4d\x5a' > "$FAKE_WARGUS/maindat.MPQ"

PEONPAD_WARGUS_DATA_DIR="$FAKE_WARGUS" \
  "$VISIONOS_STAGE_SCRIPT" >/dev/null

[[ -s "$STAGED_TEST_DIR/scripts/stratagus.lua" ]] || {
  print -u2 "staging script did not produce scripts/stratagus.lua"
  exit 1
}
# Confirm the fake proprietary archive was excluded.
if [[ -e "$STAGED_TEST_DIR/maindat.MPQ" ]]; then
  print -u2 "staging script allowed a .MPQ archive into the staged directory"
  exit 1
fi

# Confirm the staged destination is still git-ignored after the staging run.
git -C "$ROOT_DIR" check-ignore -q "$STAGED_TEST_DIR" || {
  print -u2 "staged visionOS wargus data directory is not git-ignored"
  exit 1
}

# Confirm git status is clean (staged data must not appear as untracked).
UNTRACKED=$(git -C "$ROOT_DIR" status --porcelain \
  -- "$STAGED_TEST_DIR" 2>/dev/null)
[[ -z "$UNTRACKED" ]] || {
  print -u2 "staged visionOS wargus data appeared in git status output"
  exit 1
}

# Staging must refuse a source path inside the repository root.
if PEONPAD_WARGUS_DATA_DIR="$ROOT_DIR/data.Wargus" \
    "$VISIONOS_STAGE_SCRIPT" >/dev/null 2>&1; then
  print -u2 "staging script accepted a source path inside the repository"
  exit 1
fi

# Inject script must fail clearly when staged data is absent.
cmake -E remove_directory "$STAGED_TEST_DIR"
# The inject script checks staged data before any xcrun calls, so no fake
# simulator environment is needed for this particular negative test.
if "$VISIONOS_INJECT_SCRIPT" >/dev/null 2>&1; then
  print -u2 "inject script accepted missing staged data"
  exit 1
fi

cmake -E remove_directory "$WARGUS_STAGE_ROOT"
# Restore any real staged data the developer had before the test ran.
# The EXIT trap (cleanup_wargus_staging_test) handles this automatically.
trap - EXIT
cleanup_wargus_staging_test

print "script guardrails passed"
