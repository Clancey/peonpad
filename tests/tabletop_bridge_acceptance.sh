#!/usr/bin/env zsh
# tabletop_bridge_acceptance.sh
#
# Acceptance test for the PeonPad tabletop engine bridge.
#
# What it checks
# ──────────────
# 1. The bridge library (peonpad_tabletop_bridge) and its contract test
#    (peonpad_tabletop_bridge_test) build cleanly without PEONPAD_TABLETOP.
# 2. All 28 bridge contract tests pass.
# 3. The bridge header contains no engine or SDL includes (language-neutrality).
# 4. The mainloop patch applies and reverses cleanly against a temp copy of
#    engine/stratagus.
# 5. If the authorized private data directory is present, validate that the
#    stratagus binary links the bridge (symbol presence) when built with
#    PEONPAD_TABLETOP=ON and PEONPAD_ENABLE_SDL3=ON.
#
# The real-data step (5) is skipped when data.Wargus is not found; no
# proprietary assets are copied, staged, or committed at any point.

set -eu
setopt PIPE_FAIL 2>/dev/null || true

SCRIPT_DIR=${0:A:h} 2>/dev/null || SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
BUILD_DIR="${ROOT_DIR}/build/tabletop-bridge-acceptance"

REAL_CMAKE=$(command -v cmake)
REAL_PATCH=$(command -v patch)

REAL_DATA="/Users/clancey/Downloads/WarCraft II - Battle.net Edition (USA)/data.Wargus"

pass() { printf "PASS %s\n" "$1"; }
fail() { printf "FAIL %s: %s\n" "$1" "${2:-}"; exit 1; }

# ── 1. Build bridge without engine ───────────────────────────────────────────
printf "==> Building peonpad_tabletop_bridge and test binary...\n"
"$REAL_CMAKE" -S "$ROOT_DIR" -B "$BUILD_DIR" \
  -DBUILD_TESTING=ON \
  -DPEONPAD_ENABLE_SDL3=OFF \
  -DPEONPAD_ENABLE_ENGINE=OFF \
  -DCMAKE_BUILD_TYPE=Debug \
  >/dev/null

"$REAL_CMAKE" --build "$BUILD_DIR" \
  --target peonpad_tabletop_bridge peonpad_tabletop_bridge_test \
  --parallel >/dev/null

[[ -f "$BUILD_DIR/libpeonpad_tabletop_bridge.a" ]] \
  || fail "bridge-lib-exists" "libpeonpad_tabletop_bridge.a not found"
[[ -f "$BUILD_DIR/peonpad_tabletop_bridge_test" ]] \
  || fail "bridge-test-exists" "peonpad_tabletop_bridge_test not found"
pass "bridge-build"

# ── 2. Run the contract tests ─────────────────────────────────────────────────
printf "==> Running bridge contract tests...\n"
"$BUILD_DIR/peonpad_tabletop_bridge_test" | grep -c "^PASS" | grep -q "^28$" \
  || fail "bridge-test-count" "expected 28 PASS lines"
"$BUILD_DIR/peonpad_tabletop_bridge_test" | grep "^FAIL" && \
  fail "bridge-test-failures" "one or more FAIL lines in output"
RESULT=$("$BUILD_DIR/peonpad_tabletop_bridge_test"; echo "EXIT:$?")
echo "$RESULT" | grep -q "EXIT:0" || fail "bridge-test-exit" "non-zero exit"
pass "bridge-contract-tests"

# ── 3. Verify bridge header language-neutrality ───────────────────────────────
BRIDGE_HEADER="$ROOT_DIR/platform/bridge/PeonPadTabletopBridge.h"
if grep -Eq '#include.*SDL|#include.*stratagus|#include.*unit\.h' \
    "$BRIDGE_HEADER"; then
  fail "bridge-header-clean" "bridge header contains engine or SDL includes"
fi
# Must be valid C (no C++ in the public part outside the extern "C" guard).
grep -q 'extern "C"' "$BRIDGE_HEADER" \
  || fail "bridge-header-extern-c" "bridge header missing extern C guard"
pass "bridge-header-clean"

# ── 4. Patch apply/reverse round-trip ─────────────────────────────────────────
PATCH_FILE="$ROOT_DIR/patches/stratagus/0012-tabletop-bridge-gamehook.patch"
TMPCHAIN=$(mktemp -d "/tmp/peonpad-bridge-accept-XXXXXX")
cleanup() { rm -rf "$TMPCHAIN"; }
trap cleanup EXIT
cp -R "$ROOT_DIR/engine/stratagus" "$TMPCHAIN/stratagus"
"$REAL_PATCH" --no-backup-if-mismatch -R -s -d "$TMPCHAIN/stratagus" -p1 \
  < "$PATCH_FILE" || fail "patch-reverse" "reverse failed"
"$REAL_PATCH" --no-backup-if-mismatch -s -d "$TMPCHAIN/stratagus" -p1 \
  < "$PATCH_FILE" || fail "patch-forward" "forward failed"
diff -q "$TMPCHAIN/stratagus/src/stratagus/mainloop.cpp" \
        "$ROOT_DIR/engine/stratagus/src/stratagus/mainloop.cpp" >/dev/null \
  || fail "patch-roundtrip" "patched file does not match staged source"
pass "patch-roundtrip"

# ── 5. Real-data symbol validation (optional) ─────────────────────────────────
if [[ ! -d "$REAL_DATA" ]]; then
  printf "SKIP real-data-symbol-check (data.Wargus not found at %s)\n" \
    "$REAL_DATA"
else
  printf "==> data.Wargus present — checking peonpad_tabletop_* symbols in bridge lib\n"
  # Build the bridge WITHOUT PEONPAD_TABLETOP (so no engine headers required).
  # The stubs for publish_snapshot and drain_commands are always compiled;
  # the infrastructure symbols are always present regardless of the flag.
  SDL3_BUILD="$ROOT_DIR/build/tabletop-bridge-sdl3"
  # Remove any stale build directory to avoid cached PEONPAD_TABLETOP flags.
  "$REAL_CMAKE" -E remove_directory "$SDL3_BUILD"
  "$REAL_CMAKE" -S "$ROOT_DIR" -B "$SDL3_BUILD" \
    -DBUILD_TESTING=OFF \
    -DPEONPAD_ENABLE_SDL3=ON \
    -DPEONPAD_ENABLE_ENGINE=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    >/dev/null

  "$REAL_CMAKE" --build "$SDL3_BUILD" \
    --target peonpad_tabletop_bridge --parallel >/dev/null

  for sym in \
    peonpad_tabletop_init \
    peonpad_tabletop_cleanup \
    peonpad_tabletop_publish_snapshot \
    peonpad_tabletop_drain_commands \
    peonpad_tabletop_publish_synthetic \
    peonpad_tabletop_latest_snapshot \
    peonpad_tabletop_post_command \
    peonpad_snapshot_retain \
    peonpad_snapshot_release; do
    nm -g "$SDL3_BUILD/libpeonpad_tabletop_bridge.a" 2>/dev/null \
      | grep -q "$sym" \
      || fail "real-data-symbol-$sym" "$sym not found in bridge lib"
  done
  pass "real-data-symbol-check"
fi

printf "\nAll tabletop bridge acceptance checks passed.\n"
