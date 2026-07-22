#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INPUT_LOCK="$ROOT_DIR/config/inputs.lock"
FAILURES=0
IOS_SDK_PATH=""
MODE=public

usage() {
  cat <<'EOF'
Usage: ./scripts/preflight.sh [--maintainer]

Checks the tracked PeonPad sources and Apple build toolchain. Maintainers can
add --maintainer to verify the private, immutable ref/ fixture as well.
EOF
}

case "$#" in
  0) ;;
  1)
    case "$1" in
      --maintainer) MODE=maintainer ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'unexpected argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

note() {
  printf 'INFO  %s\n' "$1"
}

manifest_value() {
  section=$1
  key=$2
  awk -F ' *= *' -v wanted_section="[$section]" -v wanted_key="$key" '
    $0 == wanted_section {in_section = 1; next}
    /^\[/ {in_section = 0}
    in_section && $1 == wanted_key {
      gsub(/"/, "", $2)
      print $2
      exit
    }
  ' "$INPUT_LOCK"
}

verify_git_input() {
  label=$1
  section=$2
  directory=$3

  if [ ! -d "$directory" ]; then
    fail "$label missing: ${directory#"$ROOT_DIR/"}"
    return
  fi

  expected_revision=$(manifest_value "$section" revision)
  if [ -z "$expected_revision" ] || [ "$expected_revision" = "MISSING" ]; then
    fail "$label revision is not locked in config/inputs.lock"
    return
  fi

  if ! actual_revision=$(GIT_OPTIONAL_LOCKS=0 git -C "$directory" \
      rev-parse HEAD 2>/dev/null); then
    fail "$label is not an inspectable Git repository: ${directory#"$ROOT_DIR/"}"
    return
  fi

  if [ "$actual_revision" = "$expected_revision" ]; then
    pass "$label revision matches $expected_revision"
  else
    fail "$label revision mismatch: expected $expected_revision, got $actual_revision"
  fi

  if [ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$directory" \
      status --porcelain --ignore-submodules=none 2>/dev/null)" ]; then
    pass "$label reference worktree is clean"
  else
    fail "$label reference worktree has uncommitted changes"
  fi
}

verify_staged_input() {
  label=$1
  section=$2
  directory=$3
  marker="$directory/.peonpad-source-revision"

  if [ ! -d "$directory" ] || [ ! -f "$marker" ]; then
    fail "$label tracked source snapshot is incomplete: ${directory#"$ROOT_DIR/"}"
    return
  fi

  expected_revision=$(manifest_value "$section" revision)
  actual_revision=$(sed -n '1p' "$marker")
  if [ -n "$expected_revision" ] && [ "$actual_revision" = "$expected_revision" ]; then
    pass "$label tracked source snapshot matches $expected_revision"
  else
    fail "$label tracked source snapshot mismatch: expected $expected_revision, got ${actual_revision:-none}"
  fi

  expected_tree_sha=$(manifest_value "$section" staged_tree_sha256)
  if [ -n "$expected_tree_sha" ]; then
    if actual_tree_sha=$("$SCRIPT_DIR/tracked-tree-sha256.sh" "$directory") &&
        [ "$actual_tree_sha" = "$expected_tree_sha" ]; then
      pass "$label tracked tree digest matches $expected_tree_sha"
    else
      fail "$label tracked tree digest mismatch: expected $expected_tree_sha, got ${actual_tree_sha:-unavailable}"
    fi
  fi
}

if [ "$MODE" = maintainer ]; then
  printf 'PeonPad maintainer preflight\n'
else
  printf 'PeonPad public build preflight\n'
fi
printf 'Workspace: %s\n\n' "$ROOT_DIR"

if [ ! -f "$INPUT_LOCK" ]; then
  fail "input manifest missing: config/inputs.lock"
  EXPECTED_REF_DIGEST=""
else
  pass "input manifest exists"
  EXPECTED_REF_DIGEST=$(awk -F ' *= *' \
    '$1 == "tree_sha256" {gsub(/"/, "", $2); print $2; exit}' \
    "$INPUT_LOCK")

  UNRESOLVED_COUNT=$(grep -c ' = "MISSING' "$INPUT_LOCK" || true)
  if [ "$UNRESOLVED_COUNT" -eq 0 ]; then
    pass "input manifest has no unresolved revisions, hashes, licenses, or tools"
  else
    fail "input manifest contains $UNRESOLVED_COUNT unresolved value(s)"
  fi
fi

if git -C "$ROOT_DIR" check-ignore -q --no-index ref/; then
  pass "ref/ is ignored by Git"
else
  fail "ref/ is not ignored by Git"
fi

if [ -z "$(git -C "$ROOT_DIR" ls-files -- ref)" ]; then
  pass "ref/ has no tracked files"
else
  fail "ref/ contains tracked files"
fi

if git -C "$ROOT_DIR" check-ignore -q --no-index data.Wargus/; then
  pass "user-owned data.Wargus/ is ignored by Git"
else
  fail "data.Wargus/ is not ignored by Git"
fi

printf '\nTracked build inputs\n'
verify_staged_input "Stratagus" "sources.stratagus" \
  "$ROOT_DIR/engine/stratagus"
verify_staged_input "Wargus" "sources.wargus" \
  "$ROOT_DIR/game/wargus"

START_REF_DIGEST=""
if [ "$MODE" = maintainer ]; then
  printf '\nMaintainer reference inputs\n'
  if [ -d "$ROOT_DIR/ref" ]; then
    START_REF_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
    if [ -n "$EXPECTED_REF_DIGEST" ] && \
        [ "$START_REF_DIGEST" = "$EXPECTED_REF_DIGEST" ]; then
      pass "immutable ref/ digest matches config/inputs.lock"
    else
      fail "ref/ digest differs from config/inputs.lock (got $START_REF_DIGEST)"
    fi
  else
    fail "ref/ directory is missing"
  fi

  verify_git_input "Stratagus source" "sources.stratagus" \
    "${PEONPAD_REF_STRATAGUS:-$ROOT_DIR/ref/stratagus}"
  verify_git_input "Wargus source" "sources.wargus" \
    "${PEONPAD_REF_WARGUS:-$ROOT_DIR/ref/wargus}"
  verify_git_input "Stratagus Vita source" "sources.stratagus_vita" \
    "${PEONPAD_REF_VITA:-$ROOT_DIR/ref/stratagus-vita}"
  verify_git_input "Aleona's Tales source" "assets.aleonas_tales" \
    "${PEONPAD_REF_ALEONA:-$ROOT_DIR/ref/aleonas-tales}"
fi

printf '\nHost toolchain\n'
if command -v cmake >/dev/null 2>&1; then
  CMAKE_VERSION_LINE=$(cmake --version | sed -n '1p')
  CMAKE_VERSION=$(printf '%s\n' "$CMAKE_VERSION_LINE" | awk '{print $3}')
  pass "CMake available: $CMAKE_VERSION_LINE"
  if awk -v version="$CMAKE_VERSION" 'BEGIN {
      split(version, parts, ".")
      exit !((parts[1] + 0) > 3 ||
             ((parts[1] + 0) == 3 && (parts[2] + 0) >= 28))
    }'; then
    pass "CMake supports native visionOS configuration (3.28+)"
  else
    note "CMake 3.28+ is required only for native visionOS; non-visionOS remains 3.27+"
  fi
else
  fail "CMake is missing"
fi

if command -v clang >/dev/null 2>&1; then
  pass "Clang available: $(clang --version | sed -n '1p')"
else
  fail "Clang is missing"
fi

if command -v xcode-select >/dev/null 2>&1; then
  DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
else
  DEVELOPER_DIR=""
fi

case "$DEVELOPER_DIR" in
  */Xcode*.app/Contents/Developer)
    pass "full Xcode selected: $DEVELOPER_DIR"
    ;;
  *)
    fail "full Xcode is not selected (current: ${DEVELOPER_DIR:-none})"
    ;;
esac

if command -v xcodebuild >/dev/null 2>&1 && \
    XCODE_VERSION=$(xcodebuild -version 2>/dev/null); then
  pass "xcodebuild available: $(printf '%s' "$XCODE_VERSION" | sed -n '1p')"
else
  fail "xcodebuild is unavailable with the selected developer directory"
fi

if IOS_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null); then
  pass "iPhoneOS SDK available: $IOS_SDK_PATH"
else
  IOS_SDK_PATH=""
  fail "iPhoneOS SDK is unavailable"
fi

printf '\nCompile probes\n'
if command -v cmake >/dev/null 2>&1; then
  if cmake --fresh -S "$ROOT_DIR" -B "$ROOT_DIR/build/preflight-macos" \
      -DPEONPAD_ENABLE_ENGINE=OFF >/dev/null && \
      cmake --build "$ROOT_DIR/build/preflight-macos" >/dev/null && \
      ctest --test-dir "$ROOT_DIR/build/preflight-macos" \
        --output-on-failure >/dev/null; then
    pass "native macOS C/C++ toolchain probe compiled"
  else
    fail "native macOS C/C++ toolchain probe failed"
  fi

  if [ -n "$IOS_SDK_PATH" ]; then
    if cmake --fresh -S "$ROOT_DIR" \
        -B "$ROOT_DIR/build/preflight-ios-arm64" \
        -G "Unix Makefiles" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DPEONPAD_ENABLE_ENGINE=OFF >/dev/null && \
        cmake --build "$ROOT_DIR/build/preflight-ios-arm64" >/dev/null && \
        lipo -info "$ROOT_DIR/build/preflight-ios-arm64/libpeonpad_toolchain_probe.a" \
          | grep -q 'architecture: arm64' && \
        otool -l "$ROOT_DIR/build/preflight-ios-arm64/libpeonpad_toolchain_probe.a" \
          | grep -q 'platform 2'; then
      pass "iOS arm64 C/C++ toolchain probe compiled (LC_BUILD_VERSION platform iOS)"
    else
      fail "iOS arm64 C/C++ toolchain probe failed"
    fi
  else
    fail "iOS arm64 compile probe skipped because the SDK is unavailable"
  fi
fi

if [ "$MODE" = maintainer ] && [ -n "$START_REF_DIGEST" ]; then
  END_REF_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
  if [ "$START_REF_DIGEST" = "$END_REF_DIGEST" ]; then
    pass "ref/ remained byte-for-byte unchanged during preflight"
  else
    fail "ref/ changed while preflight was running"
  fi
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  if [ "$MODE" = maintainer ]; then
    printf 'Maintainer preflight passed.\n'
  else
    printf 'Public build preflight passed.\n'
  fi
  exit 0
fi

note "$FAILURES prerequisite(s) remain unsatisfied"
exit 1
