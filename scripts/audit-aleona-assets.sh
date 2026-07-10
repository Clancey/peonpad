#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
SOURCE_DIR="$ROOT_DIR/assets/aleonas-tales/source"
LOCK_FILE="$ROOT_DIR/config/inputs.lock"
MODE=strict
DETAILS=0

usage() {
  cat <<'EOF'
Usage: ./scripts/audit-aleona-assets.sh [--strict|--local-test] [--details]

--strict      Fail unless every audited media file has a usable license grant
              (default; required for any distributable bundle).
--local-test  Report unresolved files but allow a private development build.
--details     Print every unresolved media path.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --strict) MODE=strict ;;
    --local-test) MODE=local-test ;;
    --details) DETAILS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 "unexpected argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -d "$SOURCE_DIR" ]] || {
  print -u2 "missing staged Aleona snapshot: $SOURCE_DIR"
  exit 1
}

EXPECTED_REVISION=$(awk -F ' *= *' '
  $0 == "[assets.aleonas_tales]" {in_section = 1; next}
  /^\[/ {in_section = 0}
  in_section && $1 == "revision" {
    gsub(/"/, "", $2); print $2; exit
  }
' "$LOCK_FILE")
ACTUAL_REVISION=$(<"$SOURCE_DIR/.peonpad-source-revision")
[[ "$ACTUAL_REVISION" == "$EXPECTED_REVISION" ]] || {
  print -u2 "staged Aleona revision does not match config/inputs.lock"
  exit 1
}

START_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
EXPECTED_DIGEST=$(awk -F ' *= *' \
  '$1 == "tree_sha256" {gsub(/"/, "", $2); print $2; exit}' \
  "$LOCK_FILE")
[[ "$START_DIGEST" == "$EXPECTED_DIGEST" ]] || {
  print -u2 "ref/ does not match config/inputs.lock; refusing asset audit"
  exit 1
}

VENDOR_DIR="$SOURCE_DIR/vendor/wyrmsun"
VENDOR_README="$VENDOR_DIR/readme.txt"
VENDOR_LICENSE="$VENDOR_DIR/license.txt"
[[ -f "$VENDOR_README" && -f "$VENDOR_LICENSE" ]] || {
  print -u2 "Wyrmsun license metadata is incomplete"
  exit 1
}
grep -Eq 'artwork, sounds, music and story elements.*GPL 2\.0' \
  "$VENDOR_README" || {
  print -u2 "Wyrmsun blanket asset declaration was not found"
  exit 1
}
grep -q 'GNU GENERAL PUBLIC LICENSE' "$VENDOR_LICENSE" || {
  print -u2 "Wyrmsun GPLv2 text was not found"
  exit 1
}

typeset -a steam_only_present vendor_cc_missing attribution_only missing_sidecar
while IFS= read -r vendor_path; do
  [[ -n "$vendor_path" ]] || continue
  [[ ! -e "$VENDOR_DIR/$vendor_path" ]] || \
    steam_only_present+=("vendor/wyrmsun/$vendor_path")
done < <(awk '/\(Steam-only\)/ {gsub(/^\//, "", $1); print $1}' "$VENDOR_README")
while IFS= read -r vendor_path; do
  [[ -n "$vendor_path" ]] || continue
  [[ -e "$VENDOR_DIR/$vendor_path" ]] || \
    vendor_cc_missing+=("vendor/wyrmsun/$vendor_path")
done < <(awk '/\(licensed under the CC-BY-SA 3\.0/ {
  gsub(/^\//, "", $1); print $1
}' "$VENDOR_README")

integer total_media=0 vendor_declared=0 explicit_nonvendor=0
while IFS= read -r -d '' file; do
  relative=${file#$SOURCE_DIR/}
  extension=${file##*.}
  extension=${extension:l}
  case "$extension" in
    png|bmp|jpg|jpeg|wav|ogg|mod|sf2|rgb|gimp)
      (( ++total_media ))
      if [[ "$relative" == vendor/wyrmsun/* ]]; then
        (( ++vendor_declared ))
        continue
      fi

      sidecar=""
      if [[ -f "$file.txt" ]]; then
        sidecar="$file.txt"
      elif [[ -f "${file%.*}.txt" ]]; then
        sidecar="${file%.*}.txt"
      fi

      if [[ -z "$sidecar" ]]; then
        missing_sidecar+=("$relative")
      elif grep -Eiq \
          '(^|[^[:alpha:]])(GPL([ -]?v?2)?|CC[- ]?BY(-SA)?|CC0|public domain|Creative Commons|License:)' \
          "$sidecar"; then
        (( ++explicit_nonvendor ))
      else
        attribution_only+=("$relative")
      fi
      ;;
  esac
done < <(find "$SOURCE_DIR" -type f -print0)

integer unresolved=$(( ${#steam_only_present} + ${#vendor_cc_missing} \
  + ${#attribution_only} + ${#missing_sidecar} ))

print "Aleona asset audit"
print "  revision:                    $ACTUAL_REVISION"
print "  media files inspected:       $total_media"
print "  Wyrmsun declared GPL/CC:      $vendor_declared"
print "  explicit non-vendor grants:  $explicit_nonvendor"
print "  attribution without grant:   ${#attribution_only}"
print "  missing adjacent provenance: ${#missing_sidecar}"
print "  forbidden Steam-only files:  ${#steam_only_present}"
print "  missing Wyrmsun CC files:     ${#vendor_cc_missing}"
print "  unresolved media files:      $unresolved"

if (( DETAILS )); then
  for asset_path in "${steam_only_present[@]}"; do print "STEAM_ONLY $asset_path"; done
  for asset_path in "${vendor_cc_missing[@]}"; do print "VENDOR_CC_MISSING $asset_path"; done
  for asset_path in "${attribution_only[@]}"; do print "ATTRIBUTION_ONLY $asset_path"; done
  for asset_path in "${missing_sidecar[@]}"; do print "MISSING_PROVENANCE $asset_path"; done
fi

END_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
[[ "$END_DIGEST" == "$START_DIGEST" ]] || {
  print -u2 "FATAL: ref/ changed during the Aleona asset audit"
  exit 70
}

if (( unresolved == 0 )); then
  print "PASS  audited media are eligible for bundling"
  exit 0
fi

if [[ "$MODE" == local-test ]]; then
  print "LOCAL-TEST ONLY: unresolved provenance forbids distribution."
  exit 0
fi

print -u2 "FAIL  Aleona is not approved for a distributable bundle."
print -u2 "      Author attribution alone is not a redistribution license."
exit 1
