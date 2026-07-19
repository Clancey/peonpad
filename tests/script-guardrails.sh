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

print "script guardrails passed"
