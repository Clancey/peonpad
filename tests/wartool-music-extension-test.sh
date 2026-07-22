#!/bin/zsh
# Regression test: wartool.cpp music extension fallback logic
#
# Two-tiered:
#  Tier 1 (always runs): Source contract — verify the .mid-first fallback is
#           present in wartool.cpp so a code revert is caught in CI.
#  Tier 2 (optional): Behavioral — if WARGUS_TEST_DATA_DIR is set to an
#           extracted BNE data directory produced by a previous wartool run,
#           verify that wc2-config.lua records .mid (not .wav).
#
# No proprietary data is read, staged, or referenced. Tier 2 requires only
# the presence of a previously-extracted output directory, not raw disc data.

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
WARTOOL_SRC="$ROOT_DIR/game/wargus/wartool.cpp"
PASS=0
FAIL=0

fail() { print -u2 "FAIL: $*"; (( FAIL++ )) || : }
pass() { print "PASS: $*"; (( PASS++ )) || : }

# ── Tier 1: Source contract ───────────────────────────────────────────────────
# The fix (PR #7) ensures that when rip < 0 (ffmpeg WAV→OGG conversion failed),
# wartool checks for an existing .mid file before defaulting to .wav.
# Pattern we require (modulo whitespace):
#   if (access(buf, F_OK) == 0) {          <- mid file existence check
#       fprintf(f, "... = \".mid\"\n");    <- uses .mid
#   } else {
#       fprintf(f, "... = \".wav\"\n");    <- only falls back to .wav

[[ -f "$WARTOOL_SRC" ]] || { fail "wartool.cpp not found at $WARTOOL_SRC"; exit 1; }

# Must contain access() check for .mid before falling back to .wav
if grep -q 'access(buf, F_OK) == 0' "$WARTOOL_SRC"; then
    pass "wartool.cpp contains access() guard for .mid existence"
else
    fail "wartool.cpp missing access() guard — .mid-first fallback was removed"
fi

# The .wav default must be guarded inside an 'else' (not unconditional)
# Check: the .wav fprintf appears after "else {" in the rip<0 block
if awk '
    /rip < 0/ { in_block=1 }
    in_block && /access\(buf, F_OK\)/ { found_access=1 }
    in_block && found_access && /music_extension.*\.wav/ { found_wav_in_else=1 }
    END { exit(!found_wav_in_else) }
' "$WARTOOL_SRC"; then
    pass "wartool.cpp: .wav fallback is guarded by access() check, not unconditional"
else
    fail "wartool.cpp: .wav fallback may be unconditional — fix logic is suspect"
fi

# The .mid arm in the else block must also be present
# In C source, quotes are backslash-escaped: wargus.music_extension = \".mid\"
if grep -q 'music_extension.*\\."\.mid' "$WARTOOL_SRC" 2>/dev/null || \
   grep -q 'music_extension.*\.mid' "$WARTOOL_SRC"; then
    COUNT=$(grep -c 'music_extension.*\.mid' "$WARTOOL_SRC")
    if (( COUNT >= 2 )); then
        pass "wartool.cpp: .mid extension output present in both rip==0 and rip<0 paths ($COUNT occurrences)"
    else
        fail "wartool.cpp: .mid extension output only appears $COUNT time(s); expected ≥2 (rip==0 path + rip<0 access path)"
    fi
else
    fail "wartool.cpp: .mid music extension string not found at all"
fi

# ── Tier 2: Behavioral (data-conditional) ────────────────────────────────────
WARGUS_TEST_DATA_DIR=${WARGUS_TEST_DATA_DIR:-}
if [[ -n "$WARGUS_TEST_DATA_DIR" && -d "$WARGUS_TEST_DATA_DIR" ]]; then
    CONFIG="$WARGUS_TEST_DATA_DIR/scripts/wc2-config.lua"
    if [[ -f "$CONFIG" ]]; then
        EXTENSION=$(awk -F '"' '/music_extension/ {print $2}' "$CONFIG")
        case "$EXTENSION" in
            .mid)
                pass "wc2-config.lua reports music_extension = .mid (BNE MIDI path correct)"
                ;;
            .wav)
                fail "wc2-config.lua reports music_extension = .wav — pre-fix behavior; BNE MIDI files not being found"
                ;;
            .ogg)
                pass "wc2-config.lua reports music_extension = .ogg (ripped OGG path — not the BNE default, but valid)"
                ;;
            *)
                fail "wc2-config.lua has unexpected music_extension = '$EXTENSION'"
                ;;
        esac
    else
        print "SKIP: Tier 2 data dir set but $CONFIG not found (run wartool first)"
    fi
else
    print "SKIP: Tier 2 behavioral test — set WARGUS_TEST_DATA_DIR=<extracted data dir> to enable"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
print ""
print "wartool-music-extension: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
