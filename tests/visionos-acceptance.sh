#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
ACCEPTANCE="$ROOT_DIR/scripts/accept-visionos.sh"
SELECTOR="$ROOT_DIR/scripts/find-vision-pro-simulator.sh"
VERIFIER="$ROOT_DIR/scripts/verify-visionos-bundle.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
REAL_CMAKE=$(command -v cmake)
REAL_GIT=$(command -v git)
ORIGINAL_PATH=$PATH
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/peonpad-visionos-tests.XXXXXX")
FAKE_BIN="$TEMP_ROOT/fake tools"
BINARY_BIN="$TEMP_ROOT/binary tools"
HOST_BIN="$TEMP_ROOT/host tools"
mkdir -p "$FAKE_BIN" "$BINARY_BIN" "$HOST_BIN"

cleanup() {
  chmod -R u+w "$TEMP_ROOT" >/dev/null 2>&1 || :
  "$REAL_CMAKE" -E remove_directory "$TEMP_ROOT"
  "$REAL_CMAKE" -E remove_directory \
    "$ROOT_DIR/build/visionos-acceptance-regression"
}
trap cleanup EXIT

cp "$FIXTURES/fake-visionos-acceptance-xcrun.sh" "$FAKE_BIN/xcrun"
cp "$FIXTURES/fake-visionos-acceptance-cmake.sh" "$FAKE_BIN/cmake"
cp "$FIXTURES/fake-visionos-acceptance-xcodebuild.sh" "$FAKE_BIN/xcodebuild"
for tool in lipo otool codesign find xcrun; do
  cp "$FIXTURES/fake-visionos-binary-tool.sh" "$BINARY_BIN/$tool"
done
for tool in git plutil mv; do
  cp "$FIXTURES/fake-visionos-acceptance-host-tool.sh" "$HOST_BIN/$tool"
done
chmod +x "$FAKE_BIN"/* "$BINARY_BIN"/* "$HOST_BIN"/*

VISION_25=11111111-1111-1111-1111-111111111111
VISION_264=22222222-2222-2222-2222-222222222222
VISION_265=33333333-3333-3333-3333-333333333333
IPAD=44444444-4444-4444-4444-444444444444
WRONG_RUNTIME=55555555-5555-5555-5555-555555555555
UNAVAILABLE=66666666-6666-6666-6666-666666666666
SELECTOR_STATE="$TEMP_ROOT/selector"
mkdir -p "$SELECTOR_STATE"
cat > "$SELECTOR_STATE/devices.txt" <<EOF
-- iOS 26.5 --
    Apple Vision Pro ($WRONG_RUNTIME) (Booted)
-- visionOS 2.5 --
    Apple Vision Pro ($VISION_25) (Shutdown)
-- visionOS 26.4 --
    Apple Vision Pro ($VISION_264) (Booted)
    iPad Pro ($IPAD) (Booted)
-- visionOS 26.5 --
    Apple Vision Pro ($VISION_265) (Booted)
    Apple Vision Pro ($UNAVAILABLE) (Shutdown) (unavailable)
EOF

SELECTED=$(PATH="$FAKE_BIN:$ORIGINAL_PATH" \
  PEONPAD_TEST_ACCEPTANCE_STATE_DIR="$SELECTOR_STATE" \
  PEONPAD_TEST_SIMCTL_DEVICES_FILE="$SELECTOR_STATE/devices.txt" \
  "$SELECTOR" --details)
[[ "$SELECTED" == \
  "$VISION_265	Apple Vision Pro	visionOS 26.5	Booted" ]]

OVERRIDE=$(PATH="$FAKE_BIN:$ORIGINAL_PATH" \
  PEONPAD_TEST_ACCEPTANCE_STATE_DIR="$SELECTOR_STATE" \
  PEONPAD_TEST_SIMCTL_DEVICES_FILE="$SELECTOR_STATE/devices.txt" \
  PEONPAD_VISION_SIMULATOR_UDID="$VISION_25" \
  "$SELECTOR")
[[ "$OVERRIDE" == "$VISION_25" ]]

for invalid in not-a-udid "$IPAD" "$WRONG_RUNTIME" "$UNAVAILABLE"; do
  if PATH="$FAKE_BIN:$ORIGINAL_PATH" \
      PEONPAD_TEST_ACCEPTANCE_STATE_DIR="$SELECTOR_STATE" \
      PEONPAD_TEST_SIMCTL_DEVICES_FILE="$SELECTOR_STATE/devices.txt" \
      PEONPAD_VISION_SIMULATOR_UDID="$invalid" \
      "$SELECTOR" >/dev/null 2>&1; then
    print -u2 "selector accepted invalid override: $invalid"
    exit 1
  fi
done

make_bundle() {
  local app=$1
  local supported_platform=$2
  mkdir -p "$app"
  cp "$ROOT_DIR/platform/apple/visionos/Info.plist.in" "$app/Info.plist"
  plutil -replace CFBundleIdentifier -string org.peonpad.visionos \
    "$app/Info.plist"
  plutil -remove CFBundleSupportedPlatforms "$app/Info.plist"
  plutil -insert CFBundleSupportedPlatforms -array "$app/Info.plist"
  plutil -insert CFBundleSupportedPlatforms.0 -string \
    "$supported_platform" "$app/Info.plist"
  print '#!/bin/sh' > "$app/PeonPadVisionShell"
  print 'exit 0' >> "$app/PeonPadVisionShell"
  chmod +x "$app/PeonPadVisionShell"
  print 'compiled assets' > "$app/Assets.car"
}

VERIFY_ROOT="$TEMP_ROOT/bundle verification"
SIM_APP="$VERIFY_ROOT/Simulator App.app"
make_bundle "$SIM_APP" XRSimulator
mkdir -p "$SIM_APP/Frameworks/Fake.framework"
print '#!/bin/sh' > "$SIM_APP/Frameworks/Fake.framework/Fake"
chmod +x "$SIM_APP/Frameworks/Fake.framework/Fake"
PATH="$BINARY_BIN:$ORIGINAL_PATH" \
  PEONPAD_TEST_MACHO_PLATFORM=12 \
  PEONPAD_TEST_CODESIGN_MODE=adhoc \
  PEONPAD_TEST_EMBEDDED_DEPENDENCY=1 \
  "$VERIFIER" xrsimulator "$SIM_APP" \
    --metadata "$VERIFY_ROOT/simulator metadata.json" >/dev/null
[[ "$(plutil -extract platform raw \
  "$VERIFY_ROOT/simulator metadata.json")" == 12 ]]
[[ "$(plutil -extract framework_count raw \
  "$VERIFY_ROOT/simulator metadata.json")" == 1 ]]

plutil -replace CFBundleIcons.CFBundlePrimaryIcon -string MissingIcon \
  "$SIM_APP/Info.plist"
if PATH="$BINARY_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_MACHO_PLATFORM=12 \
    PEONPAD_TEST_CODESIGN_MODE=adhoc \
    "$VERIFIER" xrsimulator "$SIM_APP" >/dev/null 2>&1; then
  print -u2 "bundle verifier accepted a nonexistent declared primary icon"
  exit 1
fi
plutil -replace CFBundleIcons.CFBundlePrimaryIcon -string AppIcon \
  "$SIM_APP/Info.plist"

if PATH="$BINARY_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_MACHO_PLATFORM=12 \
    PEONPAD_TEST_CODESIGN_MODE=adhoc \
    PEONPAD_TEST_COMPILED_ICON=MissingIcon \
    "$VERIFIER" xrsimulator "$SIM_APP" >/dev/null 2>&1; then
  print -u2 "bundle verifier accepted a catalog without compiled AppIcon"
  exit 1
fi

if PATH="$BINARY_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_MACHO_PLATFORM=12 \
    PEONPAD_TEST_CODESIGN_MODE=adhoc \
    PEONPAD_TEST_FIND_FRAMEWORKS_FAIL=1 \
    "$VERIFIER" xrsimulator "$SIM_APP" >/dev/null 2>&1; then
  print -u2 "bundle verifier ignored framework enumeration failure"
  exit 1
fi

if PATH="$BINARY_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_MACHO_PLATFORM=12 \
    PEONPAD_TEST_CODESIGN_MODE=adhoc \
    PEONPAD_TEST_OTOOL_L_FAIL=1 \
    "$VERIFIER" xrsimulator "$SIM_APP" >/dev/null 2>&1; then
  print -u2 "bundle verifier ignored dependency inspection failure"
  exit 1
fi

mv "$SIM_APP/Frameworks/Fake.framework" \
  "$VERIFY_ROOT/Missing Fake.framework"
if PATH="$BINARY_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_MACHO_PLATFORM=12 \
    PEONPAD_TEST_CODESIGN_MODE=adhoc \
    PEONPAD_TEST_EMBEDDED_DEPENDENCY=1 \
    "$VERIFIER" xrsimulator "$SIM_APP" >/dev/null 2>&1; then
  print -u2 "bundle verifier accepted a missing embedded framework"
  exit 1
fi
mv "$VERIFY_ROOT/Missing Fake.framework" \
  "$SIM_APP/Frameworks/Fake.framework"

if PATH="$BINARY_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_MACHO_PLATFORM=11 \
    PEONPAD_TEST_CODESIGN_MODE=adhoc \
    "$VERIFIER" xrsimulator "$SIM_APP" >/dev/null 2>&1; then
  print -u2 "bundle verifier accepted the device platform as a simulator"
  exit 1
fi

print forbidden > "$SIM_APP/WAR2DAT.MPQ"
if PATH="$BINARY_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_MACHO_PLATFORM=12 \
    PEONPAD_TEST_CODESIGN_MODE=adhoc \
    "$VERIFIER" xrsimulator "$SIM_APP" >/dev/null 2>&1; then
  print -u2 "bundle verifier accepted forbidden proprietary content"
  exit 1
fi
rm "$SIM_APP/WAR2DAT.MPQ"

DEVICE_APP="$VERIFY_ROOT/Device App.app"
make_bundle "$DEVICE_APP" XROS
PATH="$BINARY_BIN:$ORIGINAL_PATH" \
  PEONPAD_TEST_MACHO_PLATFORM=11 \
  PEONPAD_TEST_CODESIGN_MODE=unsigned \
  "$VERIFIER" xros "$DEVICE_APP" >/dev/null
if PATH="$BINARY_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_MACHO_PLATFORM=11 \
    PEONPAD_TEST_CODESIGN_MODE=signed \
    "$VERIFIER" xros "$DEVICE_APP" >/dev/null 2>&1; then
  print -u2 "bundle verifier accepted an unexpectedly signed command-line xros app"
  exit 1
fi

prepare_acceptance_state() {
  local name=$1
  ACCEPTANCE_STATE="$TEMP_ROOT/$name state"
  mkdir -p "$ACCEPTANCE_STATE"
  cat > "$ACCEPTANCE_STATE/devices.txt" <<EOF
-- visionOS 26.5 --
    Apple Vision Pro ($VISION_265) (Shutdown)
EOF
}

run_acceptance() {
  local mode=$1
  shift
  env \
    PATH="$HOST_BIN:$FAKE_BIN:$ORIGINAL_PATH" \
    PEONPAD_TEST_REAL_CMAKE="$REAL_CMAKE" \
    PEONPAD_TEST_REAL_GIT="$REAL_GIT" \
    PEONPAD_TEST_ACCEPTANCE_STATE_DIR="$ACCEPTANCE_STATE" \
    PEONPAD_TEST_SIMCTL_DEVICES_FILE="$ACCEPTANCE_STATE/devices.txt" \
    PEONPAD_TEST_ACCEPTANCE_MODE="$mode" \
    PEONPAD_TEST_GIT_DIRTY_MODE="${PEONPAD_TEST_GIT_DIRTY_MODE:-}" \
    PEONPAD_TEST_RESULT_FAILURE="${PEONPAD_TEST_RESULT_FAILURE:-}" \
    PEONPAD_VISIONOS_ACCEPTANCE_TESTING=1 \
    PEONPAD_VISIONOS_BUILD_SCRIPT="$FIXTURES/fake-visionos-acceptance-build.sh" \
    PEONPAD_VISIONOS_VERIFY_SCRIPT="$FIXTURES/fake-visionos-acceptance-verify.sh" \
    PEONPAD_VISIONOS_FIND_SCRIPT="$SELECTOR" \
    PEONPAD_VISIONOS_RESIDENCY_INTERVAL=0 \
    PEONPAD_VISIONOS_ACCEPTANCE_BUILD_ROOT="$ROOT_DIR/build/visionos-acceptance-regression/$mode path" \
    "$ACCEPTANCE" "$@"
}

if PEONPAD_VISIONOS_BUILD_SCRIPT=/usr/bin/false \
    "$ACCEPTANCE" xros >/dev/null 2>&1; then
  print -u2 "production acceptance allowed a test dependency override"
  exit 1
fi

prepare_acceptance_state healthy
HAPPY_EVIDENCE="$TEMP_ROOT/happy evidence"
HAPPY_RESULT="$TEMP_ROOT/happy result.json"
run_acceptance healthy xrsimulator \
  --keep-evidence --evidence-dir "$HAPPY_EVIDENCE" \
  --result "$HAPPY_RESULT" >/dev/null
[[ -s "$HAPPY_EVIDENCE/simulator.png" ]]
[[ "$(plutil -extract status raw "$HAPPY_RESULT")" == pass ]]
[[ "$(plutil -extract lanes.xrsimulator.fresh_pid raw \
  "$HAPPY_RESULT")" == 4101 ]]
[[ "$(plutil -extract lanes.xrsimulator.relaunch_pid raw \
  "$HAPPY_RESULT")" == 4102 ]]
[[ "$(plutil -extract lanes.xrsimulator.residency_checks raw \
  "$HAPPY_RESULT")" == 6 ]]
[[ "$(plutil -extract source_state raw "$HAPPY_RESULT")" == clean ]]

prepare_acceptance_state startup-ready
STARTUP_READY_RESULT="$TEMP_ROOT/startup readiness result.json"
run_acceptance startup-ready-only xrsimulator \
  --evidence-dir "$TEMP_ROOT/startup readiness evidence" \
  --result "$STARTUP_READY_RESULT" >/dev/null
[[ "$(plutil -extract status raw "$STARTUP_READY_RESULT")" == pass ]]

prepare_acceptance_state simulator-objc-noise
OBJC_NOISE_RESULT="$TEMP_ROOT/simulator objc noise result.json"
run_acceptance simulator-objc-noise xrsimulator \
  --evidence-dir "$TEMP_ROOT/simulator objc noise evidence" \
  --result "$OBJC_NOISE_RESULT" >/dev/null
[[ "$(plutil -extract status raw "$OBJC_NOISE_RESULT")" == pass ]]

prepare_acceptance_state simulator-objc-near-miss
OBJC_NEAR_MISS_RESULT="$TEMP_ROOT/simulator objc near miss result.json"
if run_acceptance simulator-objc-near-miss xrsimulator \
    --evidence-dir "$TEMP_ROOT/simulator objc near miss evidence" \
    --result "$OBJC_NEAR_MISS_RESULT" >/dev/null 2>&1; then
  print -u2 "acceptance broadly ignored a first-party crash signature"
  exit 1
fi
[[ "$(plutil -extract failure raw "$OBJC_NEAR_MISS_RESULT")" == \
  "first logs contain a first-party fatal, SDL, Metal, viewport, safe-area, or rendering error" ]]

prepare_acceptance_state startup-fatal
STARTUP_FATAL_RESULT="$TEMP_ROOT/startup fatal result.json"
if run_acceptance startup-bracketed-fatal xrsimulator \
    --evidence-dir "$TEMP_ROOT/startup fatal evidence" \
    --result "$STARTUP_FATAL_RESULT" >/dev/null 2>&1; then
  print -u2 "acceptance ignored a bracketed startup-only renderer failure"
  exit 1
fi
[[ "$(plutil -extract failure raw "$STARTUP_FATAL_RESULT")" == \
  "first logs contain a first-party fatal, SDL, Metal, viewport, safe-area, or rendering error" ]]

prepare_acceptance_state negative-ready
NEGATIVE_READY_RESULT="$TEMP_ROOT/negative readiness result.json"
if run_acceptance negative-readiness xrsimulator \
    --evidence-dir "$TEMP_ROOT/negative readiness evidence" \
    --result "$NEGATIVE_READY_RESULT" >/dev/null 2>&1; then
  print -u2 "acceptance treated negative readiness text as ready"
  exit 1
fi
[[ "$(plutil -extract failure raw "$NEGATIVE_READY_RESULT")" == \
  "first application readiness marker was not observed" ]]

prepare_acceptance_state cleanup
CLEAN_EVIDENCE="$TEMP_ROOT/disposable evidence"
CLEAN_RESULT="$TEMP_ROOT/cleanup result.json"
run_acceptance healthy xrsimulator \
  --evidence-dir "$CLEAN_EVIDENCE" --result "$CLEAN_RESULT" >/dev/null
[[ ! -e "$CLEAN_EVIDENCE" ]]
[[ ! -e "$ROOT_DIR/build/visionos-acceptance-regression/healthy path" ]]
[[ ! -e "$ACCEPTANCE_STATE/installed" ]]
[[ "$(plutil -extract evidence.retained raw "$CLEAN_RESULT")" == false ]]

prepare_acceptance_state stale
STALE_RESULT="$TEMP_ROOT/stale result.json"
if run_acceptance stale-pid xrsimulator \
    --evidence-dir "$TEMP_ROOT/stale evidence" \
    --result "$STALE_RESULT" >/dev/null 2>&1; then
  print -u2 "acceptance accepted a stale relaunch PID"
  exit 1
fi
[[ "$(plutil -extract status raw "$STALE_RESULT")" == fail ]]
[[ "$(plutil -extract failure raw "$STALE_RESULT")" == \
  "relaunch returned the stale process identifier" ]]
[[ ! -e "$TEMP_ROOT/stale evidence" ]]

prepare_acceptance_state launch
LAUNCH_RESULT="$TEMP_ROOT/launch failure result.json"
if run_acceptance launch-failure xrsimulator \
    --evidence-dir "$TEMP_ROOT/launch failure evidence" \
    --result "$LAUNCH_RESULT" >/dev/null 2>&1; then
  print -u2 "acceptance accepted a failed simctl launch"
  exit 1
fi
[[ "$(plutil -extract status raw "$LAUNCH_RESULT")" == fail ]]
[[ ! -e "$TEMP_ROOT/launch failure evidence" ]]

prepare_acceptance_state fatal
FATAL_RESULT="$TEMP_ROOT/runtime fatal result.json"
if run_acceptance runtime-fatal xrsimulator \
    --evidence-dir "$TEMP_ROOT/runtime fatal evidence" \
    --result "$FATAL_RESULT" >/dev/null 2>&1; then
  print -u2 "acceptance ignored a first-party Metal failure"
  exit 1
fi
[[ "$(plutil -extract status raw "$FATAL_RESULT")" == fail ]]

for dirty_mode in unstaged staged untracked; do
  prepare_acceptance_state "dirty-$dirty_mode"
  DIRTY_RESULT="$TEMP_ROOT/$dirty_mode source result.json"
  if PEONPAD_TEST_GIT_DIRTY_MODE="$dirty_mode" \
      run_acceptance healthy xros \
        --evidence-dir "$TEMP_ROOT/$dirty_mode source evidence" \
        --result "$DIRTY_RESULT" >/dev/null 2>&1; then
    print -u2 "acceptance allowed $dirty_mode source input"
    exit 1
  fi
  [[ "$(plutil -extract failure raw "$DIRTY_RESULT")" == \
    "repository source inputs are not clean" ]]
  [[ "$(plutil -extract source_state raw "$DIRTY_RESULT")" == dirty ]]
  [[ ! -e "$ACCEPTANCE_STATE/builds.log" ]]
done

for result_failure in conversion invalid-conversion move invalid-move; do
  prepare_acceptance_state "result-$result_failure"
  FAILED_RESULT="$TEMP_ROOT/$result_failure result.json"
  if PEONPAD_TEST_RESULT_FAILURE="$result_failure" \
      run_acceptance healthy xros \
        --evidence-dir "$TEMP_ROOT/$result_failure evidence" \
        --result "$FAILED_RESULT" >/dev/null 2>&1; then
    print -u2 "acceptance masked $result_failure result emission"
    exit 1
  fi
  [[ ! -e "$FAILED_RESULT" ]]
done

prepare_acceptance_state unwritable
UNWRITABLE_DIR="$TEMP_ROOT/unwritable result directory"
UNWRITABLE_RESULT="$UNWRITABLE_DIR/result.json"
mkdir -p "$UNWRITABLE_DIR"
chmod 500 "$UNWRITABLE_DIR"
if run_acceptance healthy xros \
    --evidence-dir "$TEMP_ROOT/unwritable result evidence" \
    --result "$UNWRITABLE_RESULT" >/dev/null 2>&1; then
  chmod 700 "$UNWRITABLE_DIR"
  print -u2 "acceptance passed without writing to an unwritable result path"
  exit 1
fi
chmod 700 "$UNWRITABLE_DIR"
[[ ! -e "$UNWRITABLE_RESULT" ]]

prepare_acceptance_state device
DEVICE_RESULT="$TEMP_ROOT/device result.json"
run_acceptance healthy xros \
  --evidence-dir "$TEMP_ROOT/device evidence" \
  --result "$DEVICE_RESULT" >/dev/null
[[ "$(plutil -extract lanes.xros.platform raw "$DEVICE_RESULT")" == 11 ]]
[[ "$(plutil -extract lanes.xros.signature raw \
  "$DEVICE_RESULT")" == unsigned ]]

prepare_acceptance_state all
ALL_RESULT="$TEMP_ROOT/all result.json"
PEONPAD_VISIONOS_HOST_ACCEPTANCE_SCRIPT=/usr/bin/true \
  PEONPAD_VISIONOS_HOST_CTEST_COUNT=7 \
  run_acceptance healthy all \
    --evidence-dir "$TEMP_ROOT/all evidence" \
    --result "$ALL_RESULT" >/dev/null
[[ "$(plutil -extract status raw "$ALL_RESULT")" == pass ]]
[[ "$(plutil -extract tests.host_ctest_passed raw "$ALL_RESULT")" == 7 ]]
[[ "$(plutil -extract lanes.xrsimulator.status raw "$ALL_RESULT")" == pass ]]
[[ "$(plutil -extract lanes.xros.status raw "$ALL_RESULT")" == pass ]]

print "visionOS acceptance shell regressions passed"
