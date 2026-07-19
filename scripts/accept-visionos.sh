#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TEST_MODE=${PEONPAD_VISIONOS_ACCEPTANCE_TESTING:-0}
[[ "$TEST_MODE" == (0|1) ]] || {
  print -u2 "PEONPAD_VISIONOS_ACCEPTANCE_TESTING must be 0 or 1"
  exit 2
}
if [[ "$TEST_MODE" == 0 && \
    ( -n "${PEONPAD_VISIONOS_BUILD_SCRIPT:-}" \
      || -n "${PEONPAD_VISIONOS_VERIFY_SCRIPT:-}" \
      || -n "${PEONPAD_VISIONOS_FIND_SCRIPT:-}" \
      || -n "${PEONPAD_VISIONOS_HOST_ACCEPTANCE_SCRIPT:-}" \
      || -n "${PEONPAD_VISIONOS_HOST_CTEST_COUNT:-}" \
      || -n "${PEONPAD_VISIONOS_ACCEPTANCE_BUILD_ROOT:-}" \
      || -n "${PEONPAD_VISIONOS_RESIDENCY_INTERVAL:-}" ) ]]; then
  print -u2 "acceptance dependency overrides require explicit test mode"
  exit 2
fi
if [[ -n "${PEONPAD_VISIONOS_READY_PATTERN:-}" ]]; then
  print -u2 "the visionOS readiness token is fixed and cannot be overridden"
  exit 2
fi

BUILD_SCRIPT=$SCRIPT_DIR/build-visionos-shell.sh
VERIFY_SCRIPT=$SCRIPT_DIR/verify-visionos-bundle.sh
FIND_SCRIPT=$SCRIPT_DIR/find-vision-pro-simulator.sh
READY_TOKEN='PEONPAD_VISIONOS_READY=1'
RESIDENCY_INTERVAL=2
if [[ "$TEST_MODE" == 1 ]]; then
  BUILD_SCRIPT=${PEONPAD_VISIONOS_BUILD_SCRIPT:-$BUILD_SCRIPT}
  VERIFY_SCRIPT=${PEONPAD_VISIONOS_VERIFY_SCRIPT:-$VERIFY_SCRIPT}
  FIND_SCRIPT=${PEONPAD_VISIONOS_FIND_SCRIPT:-$FIND_SCRIPT}
  RESIDENCY_INTERVAL=${PEONPAD_VISIONOS_RESIDENCY_INTERVAL:-0}
fi

usage() {
  cat <<'EOF'
Usage: ./scripts/accept-visionos.sh <xrsimulator|xros|all>
  [--keep-evidence] [--evidence-dir PATH] [--result PATH]

Runs fail-fast native visionOS acceptance. Evidence and the JSON result must
remain outside the repository. Evidence is removed unless --keep-evidence is
passed; the JSON result is always retained.
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# < 1 )); then
  usage >&2
  exit 2
fi

TARGET=$1
shift
case "$TARGET" in
  xrsimulator|xros|all) ;;
  *)
    usage >&2
    exit 2
    ;;
esac

KEEP_EVIDENCE=0
EVIDENCE_DIR=""
RESULT_PATH=""
while (( $# > 0 )); do
  case "$1" in
    --keep-evidence)
      KEEP_EVIDENCE=1
      ;;
    --evidence-dir)
      (( $# >= 2 )) || {
        usage >&2
        exit 2
      }
      EVIDENCE_DIR=${2:A}
      shift
      ;;
    --result)
      (( $# >= 2 )) || {
        usage >&2
        exit 2
      }
      RESULT_PATH=${2:A}
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[[ "$RESIDENCY_INTERVAL" == <-> ]] || {
  print -u2 "PEONPAD_VISIONOS_RESIDENCY_INTERVAL must be a non-negative integer"
  exit 2
}
EVIDENCE_EXPLICIT=0
if [[ -n "$EVIDENCE_DIR" ]]; then
  EVIDENCE_EXPLICIT=1
  case "$EVIDENCE_DIR/" in
    "$ROOT_DIR/"*)
      print -u2 "visionOS acceptance evidence must remain outside the repository"
      exit 1
      ;;
  esac
  [[ ! -e "$EVIDENCE_DIR" ]] || {
    print -u2 "evidence directory must be fresh and not already exist"
    exit 1
  }
else
  EVIDENCE_BASE=${TMPDIR:-/tmp}
  EVIDENCE_BASE=${EVIDENCE_BASE:A}
  case "$EVIDENCE_BASE/" in
    "$ROOT_DIR/"*)
      print -u2 "temporary evidence base must remain outside the repository"
      exit 1
      ;;
  esac
fi

if [[ -z "$RESULT_PATH" ]]; then
  RESULT_PATH="${TMPDIR:-/tmp}/peonpad-visionos-acceptance-${TARGET}-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  RESULT_PATH=${RESULT_PATH:A}
fi
case "$RESULT_PATH/" in
  "$ROOT_DIR/"*)
    print -u2 "visionOS acceptance result must remain outside the repository"
    exit 1
    ;;
esac
if (( EVIDENCE_EXPLICIT )); then
  case "$RESULT_PATH/" in
    "$EVIDENCE_DIR/"*)
      print -u2 "result path cannot be inside the disposable evidence directory"
      exit 1
      ;;
  esac
fi
[[ ! -d "$RESULT_PATH" ]] || {
  print -u2 "result path is a directory"
  exit 1
}
[[ ! -e "$RESULT_PATH" ]] || {
  print -u2 "result path must be fresh and not already exist"
  exit 1
}
mkdir -p "${RESULT_PATH:h}"
if (( EVIDENCE_EXPLICIT )); then
  mkdir -p "$EVIDENCE_DIR"
else
  EVIDENCE_DIR=$(mktemp -d \
    "$EVIDENCE_BASE/peonpad-visionos-acceptance.XXXXXX")
fi
EVIDENCE_DIR=${EVIDENCE_DIR:A}

BUILD_ROOT=$ROOT_DIR/build/visionos-acceptance
if [[ "$TEST_MODE" == 1 ]]; then
  BUILD_ROOT=${PEONPAD_VISIONOS_ACCEPTANCE_BUILD_ROOT:-$BUILD_ROOT}
fi
BUILD_ROOT=${BUILD_ROOT:A}
case "$BUILD_ROOT/" in
  "$ROOT_DIR/build/"*) ;;
  *)
    print -u2 "acceptance build root must remain inside $ROOT_DIR/build"
    exit 1
    ;;
esac

STATUS=fail
FAILURE="acceptance did not complete"
CURRENT_CHECK=""
CHECK_ACTIVE=0
TEST_TOTAL=0
TEST_PASSED=0
HOST_CTEST_TOTAL=0
HOST_CTEST_PASSED=0
COMMIT_SHA=""
SOURCE_STATE=unknown
XCODE_VERSION=""
XCODE_BUILD=""
CMAKE_VERSION=""
SDK_XRSIMULATOR=""
SDK_XROS=""
SIM_LANE_STATUS=not_run
SIM_BUNDLE_ID=""
SIM_BUNDLE_EXECUTABLE=""
SIM_BUNDLE_PLATFORM=0
SIM_BUNDLE_MINIMUM=""
SIM_BUNDLE_SDK=""
SIM_BUNDLE_SIGNATURE=""
XROS_LANE_STATUS=not_run
XROS_BUNDLE_ID=""
XROS_BUNDLE_EXECUTABLE=""
XROS_BUNDLE_PLATFORM=0
XROS_BUNDLE_MINIMUM=""
XROS_BUNDLE_SDK=""
XROS_BUNDLE_SIGNATURE=""
SIMULATOR_MODEL=""
SIMULATOR_RUNTIME=""
SIMULATOR_STATE=""
VISION_UDID=""
FRESH_PID=0
RELAUNCH_PID=0
RESIDENCY_CHECKS=0
SCREENSHOT_PATH="$EVIDENCE_DIR/simulator.png"
INSTALLED_APP=0
FINISHING=0

begin_check() {
  CURRENT_CHECK=$1
  CHECK_ACTIVE=1
  (( TEST_TOTAL += 1 ))
  print "RUN  $CURRENT_CHECK"
}

pass_check() {
  (( TEST_PASSED += 1 ))
  CHECK_ACTIVE=0
  print "PASS $CURRENT_CHECK"
}

fail_check() {
  FAILURE=$1
  return 1
}

run_logged() {
  local label=$1
  local log_file=$2
  shift 2
  begin_check "$label"
  if "$@" >"$log_file" 2>&1; then
    pass_check
  else
    local result=$?
    FAILURE=$label
    return "$result"
  fi
}

metadata_value() {
  plutil -extract "$2" raw "$1"
}

discover_app() {
  local build_dir=$1
  local -a candidates valid
  local candidate
  candidates=(
    "$build_dir"/*.app(N)
    "$build_dir"/*/*.app(N)
    "$build_dir"/*/*/*.app(N)
  )
  valid=()
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate/Info.plist" ]] && valid+=("$candidate")
  done
  (( ${#valid[@]} == 1 )) || return 1
  print -r -- "$valid[1]"
}

validate_result_json() {
  local result_file=$1
  [[ -s "$result_file" ]] &&
    grep -Eq '^[[:space:]]*\{' "$result_file" &&
    plutil -convert xml1 -o /dev/null "$result_file" &&
    [[ "$(plutil -extract schema_version raw "$result_file")" == 1 ]] &&
    [[ "$(plutil -extract status raw "$result_file")" == "$STATUS" ]] &&
    [[ "$(plutil -extract source_state raw "$result_file")" == \
      "$SOURCE_STATE" ]]
}

write_result() {
  local result_plist="${RESULT_PATH}.plist.$$"
  local result_json="${RESULT_PATH}.json.$$"
  local passed_bool=false
  local retained_bool=false
  local test_bool=false
  local failed_count=$(( TEST_TOTAL - TEST_PASSED ))
  local generated_at
  [[ "$STATUS" == pass ]] && passed_bool=true
  [[ -d "$EVIDENCE_DIR" ]] && retained_bool=true
  [[ "$TEST_MODE" == 1 ]] && test_bool=true
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1

  if ! {
    rm -f "$result_plist" "$result_json" &&
    plutil -create xml1 "$result_plist" &&
    plutil -insert schema_version -integer 1 "$result_plist" &&
    plutil -insert status -string "$STATUS" "$result_plist" &&
    plutil -insert passed -bool "$passed_bool" "$result_plist" &&
    plutil -insert test_mode -bool "$test_bool" "$result_plist" &&
    plutil -insert failure -string "$FAILURE" "$result_plist" &&
    plutil -insert generated_at -string "$generated_at" "$result_plist" &&
    plutil -insert commit_sha -string "$COMMIT_SHA" "$result_plist" &&
    plutil -insert source_state -string "$SOURCE_STATE" "$result_plist" &&
    plutil -insert target -string "$TARGET" "$result_plist" &&
    plutil -insert configuration -string Release "$result_plist" &&
    plutil -insert build_scope -string default/all-target "$result_plist" &&
    plutil -insert result_path -string "$RESULT_PATH" "$result_plist" &&
    plutil -insert toolchain -dictionary "$result_plist" &&
    plutil -insert toolchain.xcode_version -string \
      "$XCODE_VERSION" "$result_plist" &&
    plutil -insert toolchain.xcode_build -string \
      "$XCODE_BUILD" "$result_plist" &&
    plutil -insert toolchain.cmake_version -string \
      "$CMAKE_VERSION" "$result_plist" &&
    plutil -insert toolchain.xrsimulator_sdk -string \
      "$SDK_XRSIMULATOR" "$result_plist" &&
    plutil -insert toolchain.xros_sdk -string \
      "$SDK_XROS" "$result_plist" &&
    plutil -insert tests -dictionary "$result_plist" &&
    plutil -insert tests.total -integer "$TEST_TOTAL" "$result_plist" &&
    plutil -insert tests.passed -integer "$TEST_PASSED" "$result_plist" &&
    plutil -insert tests.failed -integer "$failed_count" "$result_plist" &&
    plutil -insert tests.host_ctest_total -integer \
      "$HOST_CTEST_TOTAL" "$result_plist" &&
    plutil -insert tests.host_ctest_passed -integer \
      "$HOST_CTEST_PASSED" "$result_plist" &&
    plutil -insert evidence -dictionary "$result_plist" &&
    plutil -insert evidence.directory -string \
      "$EVIDENCE_DIR" "$result_plist" &&
    plutil -insert evidence.screenshot -string \
      "$SCREENSHOT_PATH" "$result_plist" &&
    plutil -insert evidence.first_runtime_log -string \
      "$EVIDENCE_DIR/first-first-party.log" "$result_plist" &&
    plutil -insert evidence.relaunch_runtime_log -string \
      "$EVIDENCE_DIR/relaunch-first-party.log" "$result_plist" &&
    plutil -insert evidence.xrsimulator_build_log -string \
      "$EVIDENCE_DIR/xrsimulator-build.log" "$result_plist" &&
    plutil -insert evidence.xros_build_log -string \
      "$EVIDENCE_DIR/xros-build.log" "$result_plist" &&
    plutil -insert evidence.retained -bool \
      "$retained_bool" "$result_plist" &&
    plutil -insert lanes -dictionary "$result_plist" &&
    plutil -insert lanes.xrsimulator -dictionary "$result_plist" &&
    plutil -insert lanes.xrsimulator.status -string \
      "$SIM_LANE_STATUS" "$result_plist" &&
    plutil -insert lanes.xrsimulator.bundle_identifier -string \
      "$SIM_BUNDLE_ID" "$result_plist" &&
    plutil -insert lanes.xrsimulator.executable -string \
      "$SIM_BUNDLE_EXECUTABLE" "$result_plist" &&
    plutil -insert lanes.xrsimulator.platform -integer \
      "$SIM_BUNDLE_PLATFORM" "$result_plist" &&
    plutil -insert lanes.xrsimulator.minimum_os -string \
      "$SIM_BUNDLE_MINIMUM" "$result_plist" &&
    plutil -insert lanes.xrsimulator.sdk -string \
      "$SIM_BUNDLE_SDK" "$result_plist" &&
    plutil -insert lanes.xrsimulator.signature -string \
      "$SIM_BUNDLE_SIGNATURE" "$result_plist" &&
    plutil -insert lanes.xrsimulator.simulator -dictionary \
      "$result_plist" &&
    plutil -insert lanes.xrsimulator.simulator.model -string \
      "$SIMULATOR_MODEL" "$result_plist" &&
    plutil -insert lanes.xrsimulator.simulator.runtime -string \
      "$SIMULATOR_RUNTIME" "$result_plist" &&
    plutil -insert lanes.xrsimulator.simulator.udid -string \
      "$VISION_UDID" "$result_plist" &&
    plutil -insert lanes.xrsimulator.simulator.state -string \
      "$SIMULATOR_STATE" "$result_plist" &&
    plutil -insert lanes.xrsimulator.fresh_pid -integer \
      "$FRESH_PID" "$result_plist" &&
    plutil -insert lanes.xrsimulator.relaunch_pid -integer \
      "$RELAUNCH_PID" "$result_plist" &&
    plutil -insert lanes.xrsimulator.residency_checks -integer \
      "$RESIDENCY_CHECKS" "$result_plist" &&
    plutil -insert lanes.xros -dictionary "$result_plist" &&
    plutil -insert lanes.xros.status -string \
      "$XROS_LANE_STATUS" "$result_plist" &&
    plutil -insert lanes.xros.bundle_identifier -string \
      "$XROS_BUNDLE_ID" "$result_plist" &&
    plutil -insert lanes.xros.executable -string \
      "$XROS_BUNDLE_EXECUTABLE" "$result_plist" &&
    plutil -insert lanes.xros.platform -integer \
      "$XROS_BUNDLE_PLATFORM" "$result_plist" &&
    plutil -insert lanes.xros.minimum_os -string \
      "$XROS_BUNDLE_MINIMUM" "$result_plist" &&
    plutil -insert lanes.xros.sdk -string \
      "$XROS_BUNDLE_SDK" "$result_plist" &&
    plutil -insert lanes.xros.signature -string \
      "$XROS_BUNDLE_SIGNATURE" "$result_plist" &&
    plutil -insert lanes.xros.manual_gate -string \
      "Use an Xcode build with automatic signing, a local DEVELOPMENT_TEAM, and provisioning; then explicitly install the signed platform-11 app on a paired Apple Vision Pro." \
      "$result_plist" &&
    plutil -insert warnings -array "$result_plist"
  }; then
    rm -f "$result_plist" "$result_json" "$RESULT_PATH" >/dev/null 2>&1
    return 1
  fi

  if [[ "$TARGET" == xros || "$TARGET" == all ]]; then
    if ! plutil -insert warnings.0 -string \
        "Physical-device signing, provisioning, installation, launch, and hardware behavior remain manual gates." \
        "$result_plist"; then
      rm -f "$result_plist" "$result_json" "$RESULT_PATH" >/dev/null 2>&1
      return 1
    fi
  fi

  if ! {
    plutil -convert json -o "$result_json" "$result_plist" &&
    validate_result_json "$result_json" &&
    mv "$result_json" "$RESULT_PATH" &&
    validate_result_json "$RESULT_PATH" &&
    rm -f "$result_plist"
  }; then
    rm -f "$result_plist" "$result_json" "$RESULT_PATH" >/dev/null 2>&1
    return 1
  fi
}

cleanup() {
  local cleanup_failed=0

  if (( INSTALLED_APP )) && [[ -n "$VISION_UDID" && -n "$SIM_BUNDLE_ID" ]]; then
    if ! xcrun simctl uninstall "$VISION_UDID" "$SIM_BUNDLE_ID" \
        >/dev/null 2>&1; then
      cleanup_failed=1
    elif xcrun simctl get_app_container "$VISION_UDID" "$SIM_BUNDLE_ID" app \
        >/dev/null 2>&1; then
      cleanup_failed=1
    else
      INSTALLED_APP=0
    fi
  fi

  if command -v cmake >/dev/null 2>&1; then
    cmake -E remove_directory "$BUILD_ROOT" >/dev/null 2>&1 ||
      cleanup_failed=1
    if (( ! KEEP_EVIDENCE )); then
      cmake -E remove_directory "$EVIDENCE_DIR" >/dev/null 2>&1 ||
        cleanup_failed=1
    fi
  else
    cleanup_failed=1
  fi

  return "$cleanup_failed"
}

finish() {
  local exit_code=${1:-$?}
  if (( FINISHING )); then
    return 0
  fi
  FINISHING=1
  trap - EXIT INT TERM ZERR
  set +e

  if (( exit_code == 0 )); then
    STATUS=pass
    FAILURE=""
  elif [[ "$FAILURE" == "acceptance did not complete" ]]; then
    FAILURE=${CURRENT_CHECK:-"acceptance command failed"}
  fi
  if (( exit_code != 0 && ! CHECK_ACTIVE && TEST_TOTAL == TEST_PASSED )); then
    (( TEST_TOTAL += 1 ))
  fi

  if ! cleanup; then
    if (( exit_code == 0 )); then
      exit_code=1
      STATUS=fail
      FAILURE="acceptance cleanup failed"
      (( TEST_TOTAL += 1 ))
    else
      FAILURE="$FAILURE; acceptance cleanup also failed"
      (( TEST_TOTAL += 1 ))
    fi
  fi

  if ! write_result; then
    print -u2 "FAIL visionOS acceptance could not emit its JSON result"
    exit 1
  fi

  if (( exit_code == 0 )); then
    print "PASS visionOS acceptance: $TARGET"
    print "  result:   $RESULT_PATH"
    if (( KEEP_EVIDENCE )); then
      print "  evidence: $EVIDENCE_DIR"
    else
      print "  evidence: cleaned"
    fi
  else
    print -u2 "FAIL visionOS acceptance: $FAILURE"
    print -u2 "  result: $RESULT_PATH"
  fi
  exit "$exit_code"
}

TRAPZERR() {
  local exit_code=$?
  finish "$exit_code"
}

trap 'finish $?' EXIT
trap 'FAILURE="acceptance interrupted"; finish 130' INT TERM

verify_clean_source() {
  local source_changes
  begin_check "verify clean source snapshot"
  COMMIT_SHA=$(git -C "$ROOT_DIR" rev-parse --verify HEAD) ||
    fail_check "repository HEAD could not be recorded"
  if ! source_changes=$(git -C "$ROOT_DIR" status --porcelain=v1 \
      --untracked-files=all --ignored=no); then
    fail_check "repository source state could not be inspected"
  fi
  if [[ -n "$source_changes" ]]; then
    SOURCE_STATE=dirty
    fail_check "repository source inputs are not clean"
  fi
  SOURCE_STATE=clean
  pass_check
}

collect_toolchain() {
  begin_check "collect toolchain metadata"
  XCODE_OUTPUT=$(xcodebuild -version)
  XCODE_VERSION=$(print -r -- "$XCODE_OUTPUT" |
    awk '$1 == "Xcode" {print $2; exit}')
  XCODE_BUILD=$(print -r -- "$XCODE_OUTPUT" |
    awk '$1 == "Build" && $2 == "version" {print $3; exit}')
  CMAKE_VERSION=$(cmake --version | awk 'NR == 1 {print $3}')
  if [[ "$TARGET" == xrsimulator || "$TARGET" == all ]]; then
    SDK_XRSIMULATOR=$(xcrun --sdk xrsimulator --show-sdk-version)
  fi
  if [[ "$TARGET" == xros || "$TARGET" == all ]]; then
    SDK_XROS=$(xcrun --sdk xros --show-sdk-version)
  fi
  [[ -n "$XCODE_VERSION" && -n "$CMAKE_VERSION" ]]
  pass_check
}

run_host_acceptance() {
  local host_build="$BUILD_ROOT/host"
  if [[ "$TEST_MODE" == 1 \
      && -n "${PEONPAD_VISIONOS_HOST_ACCEPTANCE_SCRIPT:-}" ]]; then
    run_logged "focused host tests and guardrails" \
      "$EVIDENCE_DIR/host-acceptance.log" \
      "$PEONPAD_VISIONOS_HOST_ACCEPTANCE_SCRIPT"
    HOST_CTEST_TOTAL=${PEONPAD_VISIONOS_HOST_CTEST_COUNT:-7}
    HOST_CTEST_PASSED=$HOST_CTEST_TOTAL
    return
  fi

  run_logged "verify locked public SDL3 sources" \
    "$EVIDENCE_DIR/sdl3-sources.log" \
    "$SCRIPT_DIR/verify-sdl3-sources.sh"
  run_logged "configure clean Release host acceptance" \
    "$EVIDENCE_DIR/host-configure.log" \
    cmake --fresh -S "$ROOT_DIR" -B "$host_build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DPEONPAD_ENABLE_ENGINE=OFF \
      -DPEONPAD_ENABLE_SDL3=ON \
      -DBUILD_TESTING=ON
  run_logged "build complete Release host default target" \
    "$EVIDENCE_DIR/host-build.log" \
    cmake --build "$host_build" --parallel

  begin_check "enumerate Release host CTests"
  CTEST_LIST=$(ctest --test-dir "$host_build" -N)
  HOST_CTEST_TOTAL=$(print -r -- "$CTEST_LIST" |
    awk '/Total Tests:/ {print $3; exit}')
  [[ "$HOST_CTEST_TOTAL" == <-> && $HOST_CTEST_TOTAL -ge 7 ]] ||
    fail_check "fewer than seven focused host CTests were configured"
  pass_check

  run_logged "run all Release host CTests" \
    "$EVIDENCE_DIR/host-ctest.log" \
    ctest --test-dir "$host_build" --output-on-failure
  HOST_CTEST_PASSED=$HOST_CTEST_TOTAL
  run_logged "run direct Release viewport and input checks" \
    "$EVIDENCE_DIR/viewport.log" \
    "$SCRIPT_DIR/test-ios-viewport.sh"
  run_logged "run public and Designed-for-iPad compatibility preflights" \
    "$EVIDENCE_DIR/public-compatibility-preflight.log" \
    "$SCRIPT_DIR/preflight-vision-compat.sh"
}

run_build_lane() {
  local lane=$1
  local build_dir="$BUILD_ROOT/$lane"
  local metadata="$EVIDENCE_DIR/$lane-bundle.json"
  local app

  if [[ "$lane" == xrsimulator ]]; then
    SIM_LANE_STATUS=fail
  else
    XROS_LANE_STATUS=fail
  fi

  run_logged "$lane clean Release all-target build and inspection" \
    "$EVIDENCE_DIR/$lane-build.log" \
    env PEONPAD_VISIONOS_BUILD_DIR="$build_dir" \
      "$BUILD_SCRIPT" "$lane"

  begin_check "$lane generated exactly one application bundle"
  app=$(discover_app "$build_dir") ||
    fail_check "$lane build did not produce exactly one application bundle"
  pass_check

  run_logged "$lane generic bundle, linkage, resource, and signing verification" \
    "$EVIDENCE_DIR/$lane-verify.log" \
    "$VERIFY_SCRIPT" "$lane" "$app" --metadata "$metadata"

  begin_check "$lane bundle SDK matches the selected toolchain"
  if [[ "$lane" == xrsimulator ]]; then
    [[ "$(metadata_value "$metadata" sdk)" == "$SDK_XRSIMULATOR" ]] ||
      fail_check "xrsimulator bundle SDK does not match xcrun"
  else
    [[ "$(metadata_value "$metadata" sdk)" == "$SDK_XROS" ]] ||
      fail_check "xros bundle SDK does not match xcrun"
  fi
  pass_check

  if [[ "$lane" == xrsimulator ]]; then
    SIM_BUNDLE_ID=$(metadata_value "$metadata" bundle_identifier)
    SIM_BUNDLE_EXECUTABLE=$(metadata_value "$metadata" executable)
    SIM_BUNDLE_PLATFORM=$(metadata_value "$metadata" platform)
    SIM_BUNDLE_MINIMUM=$(metadata_value "$metadata" minimum_os)
    SIM_BUNDLE_SDK=$(metadata_value "$metadata" sdk)
    SIM_BUNDLE_SIGNATURE=$(metadata_value "$metadata" signature)
    SIM_APP=$app
  else
    XROS_BUNDLE_ID=$(metadata_value "$metadata" bundle_identifier)
    XROS_BUNDLE_EXECUTABLE=$(metadata_value "$metadata" executable)
    XROS_BUNDLE_PLATFORM=$(metadata_value "$metadata" platform)
    XROS_BUNDLE_MINIMUM=$(metadata_value "$metadata" minimum_os)
    XROS_BUNDLE_SDK=$(metadata_value "$metadata" sdk)
    XROS_BUNDLE_SIGNATURE=$(metadata_value "$metadata" signature)
    XROS_LANE_STATUS=pass
  fi
}

select_and_boot_simulator() {
  local details
  begin_check "select an available Apple Vision Pro on visionOS"
  details=$("$FIND_SCRIPT" --details 2>"$EVIDENCE_DIR/simulator-selection.log") ||
    fail_check "Apple Vision Pro simulator selection failed"
  IFS=$'\t' read -r VISION_UDID SIMULATOR_MODEL SIMULATOR_RUNTIME SIMULATOR_STATE \
    <<< "$details"
  [[ "$SIMULATOR_MODEL" == "Apple Vision Pro" \
      && "$SIMULATOR_RUNTIME" == visionOS\ * \
      && "$SIMULATOR_STATE" == (Booted|Shutdown) ]] ||
    fail_check "simulator selection returned an invalid model, runtime, or state"
  pass_check

  if [[ "$SIMULATOR_STATE" == Shutdown ]]; then
    run_logged "boot selected Apple Vision Pro simulator" \
      "$EVIDENCE_DIR/simulator-boot.log" \
      xcrun simctl boot "$VISION_UDID"
  fi
  run_logged "wait for Apple Vision Pro boot completion" \
    "$EVIDENCE_DIR/simulator-bootstatus.log" \
    xcrun simctl bootstatus "$VISION_UDID" -b
  SIMULATOR_STATE=Booted
}

bundle_manifest() {
  local bundle=$1
  (
    cd "$bundle"
    find . -type f -print | LC_ALL=C sort |
      while IFS= read -r relative_path; do
        digest=$(shasum -a 256 "$relative_path" |
          awk '{print $1}')
        print -r -- "$digest	$relative_path"
      done
  )
}

install_fresh_app() {
  local container
  run_logged "install freshly built simulator application" \
    "$EVIDENCE_DIR/simulator-install.log" \
    xcrun simctl install "$VISION_UDID" "$SIM_APP"
  INSTALLED_APP=1

  begin_check "installed simulator application matches the fresh bundle"
  container=$(xcrun simctl get_app_container \
    "$VISION_UDID" "$SIM_BUNDLE_ID" app)
  [[ -d "$container" ]] ||
    fail_check "installed application container is unavailable"
  cmp -s "$SIM_APP/Info.plist" "$container/Info.plist" ||
    fail_check "installed application metadata is stale"
  cmp -s "$SIM_APP/$SIM_BUNDLE_EXECUTABLE" \
    "$container/$SIM_BUNDLE_EXECUTABLE" ||
    fail_check "installed application executable is stale"
  bundle_manifest "$SIM_APP" > "$EVIDENCE_DIR/built-bundle.sha256"
  bundle_manifest "$container" > "$EVIDENCE_DIR/installed-bundle.sha256"
  cmp -s "$EVIDENCE_DIR/built-bundle.sha256" \
    "$EVIDENCE_DIR/installed-bundle.sha256" ||
    fail_check "installed application resources are stale"
  pass_check
}

launch_application() {
  local ordinal=$1
  local stdout_file="$EVIDENCE_DIR/$ordinal-stdout.log"
  local stderr_file="$EVIDENCE_DIR/$ordinal-stderr.log"
  local launch_log="$EVIDENCE_DIR/$ordinal-launch.log"
  local launch_result pid

  : > "$stdout_file"
  : > "$stderr_file"
  : > "$launch_log"
  begin_check "$ordinal fresh application launch"
  LAST_LAUNCH_EPOCH=$(date +%s)
  if launch_result=$(xcrun simctl launch --terminate-running-process \
      "--stdout=$stdout_file" "--stderr=$stderr_file" \
      "$VISION_UDID" "$SIM_BUNDLE_ID" 2>"$launch_log"); then
    print -r -- "$launch_result" >> "$launch_log"
  else
    fail_check "$ordinal application launch failed"
  fi
  pid=$(print -r -- "$launch_result" |
    awk -F ': ' -v bundle="$SIM_BUNDLE_ID" \
      '$1 == bundle && $2 ~ /^[0-9]+$/ {print $2; exit}')
  [[ "$pid" == <-> && $pid -gt 0 ]] ||
    fail_check "$ordinal launch did not return a process identifier"
  LAST_LAUNCH_PID=$pid
  pass_check
}

procinfo_is_resident() {
  local procinfo_file=$1
  grep -Fq "bundle id = $SIM_BUNDLE_ID" "$procinfo_file" &&
    grep -Eq '^[[:space:]]*state = running$' "$procinfo_file" &&
    grep -F "program path = " "$procinfo_file" |
      grep -Fq "/$SIM_BUNDLE_EXECUTABLE"
}

readiness_observed() {
  awk -v token="$READY_TOKEN" '
    {
      sub(/\r$/, "")
      token_start = length($0) - length(token) + 1
      if ($0 == token ||
          (token_start > 1 &&
           substr($0, token_start) == token &&
           substr($0, token_start - 1, 1) ~ /[[:space:]]/)) {
        found = 1
      }
    }
    END {exit !found}
  ' "$@"
}

verify_residency_and_logs() {
  local ordinal=$1
  local pid=$2
  local stdout_file="$EVIDENCE_DIR/$ordinal-stdout.log"
  local stderr_file="$EVIDENCE_DIR/$ordinal-stderr.log"
  local unified_file="$EVIDENCE_DIR/$ordinal-unified.log"
  local first_party_file="$EVIDENCE_DIR/$ordinal-first-party.log"
  local index
  local fatal_pattern='(fatal|assertion failed|uncaught exception|abort trap|crash)|(PeonPad|SDL|Metal|render(er|ing)?|viewport|safe[- ]?area).*(error|failed|failure|invalid|unavailable|missing)|(error|failed|failure|invalid|unavailable|missing).*(PeonPad|SDL|Metal|render(er|ing)?|viewport|safe[- ]?area)'

  for index in 1 2 3; do
    sleep "$RESIDENCY_INTERVAL"
    begin_check "$ordinal residency check $index"
    PROCINFO_FILE="$EVIDENCE_DIR/$ordinal-residency-$index.log"
    if ! xcrun simctl spawn "$VISION_UDID" \
        launchctl procinfo "$pid" >"$PROCINFO_FILE" 2>&1; then
      fail_check "$ordinal process was not resident at check $index"
    fi
    procinfo_is_resident "$PROCINFO_FILE" ||
      fail_check "$ordinal process residency metadata was stale at check $index"
    pass_check
    (( RESIDENCY_CHECKS += 1 ))
  done

  begin_check "$ordinal scoped runtime log capture"
  if xcrun simctl spawn "$VISION_UDID" log show \
      --style compact --color none --no-pager --info --debug \
      --start "@$LAST_LAUNCH_EPOCH" --process "$pid" \
      >"$unified_file" 2>"$EVIDENCE_DIR/$ordinal-log-query.log"; then
    :
  else
    fail_check "$ordinal scoped runtime logs could not be captured"
  fi
  pass_check

  begin_check "$ordinal explicit readiness marker"
  readiness_observed \
    "$stdout_file" "$stderr_file" "$unified_file" ||
    fail_check "$ordinal application readiness marker was not observed"
  pass_check

  begin_check "$ordinal first-party fatal/render/runtime log scan"
  awk -v process="$SIM_BUNDLE_EXECUTABLE" '
    {
      marker = process "["
      marker_start = index($0, marker)
      if (!marker_start) next
      message = substr($0, marker_start + length(marker))
      marker_end = index(message, "] ")
      if (!marker_end) {
        print
        next
      }
      message = substr(message, marker_end + 2)
      if (message == "[com.apple.Accessibility:AXLoading] Failed to load a system Framework") {
        next
      }
      print message
    }
  ' "$unified_file" > "$first_party_file"
  if grep -Eiq "$fatal_pattern" \
      "$stdout_file" "$stderr_file" "$first_party_file"; then
    fail_check "$ordinal logs contain a first-party fatal, SDL, Metal, viewport, safe-area, or rendering error"
  fi
  pass_check
}

capture_screenshot() {
  begin_check "capture fresh simulator screenshot"
  [[ ! -e "$SCREENSHOT_PATH" ]] ||
    fail_check "simulator screenshot path was not fresh"
  xcrun simctl io "$VISION_UDID" screenshot "$SCREENSHOT_PATH" \
    >"$EVIDENCE_DIR/screenshot.log" 2>&1
  [[ -s "$SCREENSHOT_PATH" ]] ||
    fail_check "simulator screenshot was not captured"
  SCREENSHOT_MTIME=$(stat -f %m "$SCREENSHOT_PATH")
  [[ "$SCREENSHOT_MTIME" == <-> \
      && $SCREENSHOT_MTIME -ge $LAST_LAUNCH_EPOCH ]] ||
    fail_check "simulator screenshot is stale"
  pass_check
}

terminate_application() {
  local pid=$1
  run_logged "terminate first accepted application process" \
    "$EVIDENCE_DIR/terminate.log" \
    xcrun simctl terminate "$VISION_UDID" "$SIM_BUNDLE_ID"

  begin_check "confirm terminated process is no longer resident"
  xcrun simctl spawn "$VISION_UDID" launchctl procinfo "$pid" \
    >"$EVIDENCE_DIR/terminated-procinfo.log" 2>&1 || :
  if procinfo_is_resident "$EVIDENCE_DIR/terminated-procinfo.log"; then
    fail_check "terminated application process remained resident"
  fi
  pass_check
}

run_simulator_runtime() {
  select_and_boot_simulator
  install_fresh_app

  launch_application first
  FRESH_PID=$LAST_LAUNCH_PID
  verify_residency_and_logs first "$FRESH_PID"
  capture_screenshot
  terminate_application "$FRESH_PID"

  launch_application relaunch
  RELAUNCH_PID=$LAST_LAUNCH_PID
  [[ "$RELAUNCH_PID" != "$FRESH_PID" ]] ||
    fail_check "relaunch returned the stale process identifier"
  verify_residency_and_logs relaunch "$RELAUNCH_PID"
  SIM_LANE_STATUS=pass
}

verify_clean_source
collect_toolchain
if [[ "$TARGET" == all ]]; then
  run_host_acceptance
fi
if [[ "$TARGET" == xrsimulator || "$TARGET" == all ]]; then
  run_build_lane xrsimulator
  run_simulator_runtime
fi
if [[ "$TARGET" == xros || "$TARGET" == all ]]; then
  run_build_lane xros
fi
