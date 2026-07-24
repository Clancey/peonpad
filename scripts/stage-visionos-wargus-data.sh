#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
SOURCE_DIR=${PEONPAD_WARGUS_DATA_DIR:-$ROOT_DIR/data.Wargus}
DEST_DIR="$ROOT_DIR/build/visionos-wargus-data"

usage() {
  cat <<'EOF'
Usage: ./scripts/stage-visionos-wargus-data.sh

Validates an already-extracted private Wargus data directory and stages its
content into build/visionos-wargus-data/, which the native visionOS runtime
and simulator injection tooling treat as the canonical read-only game-data
root.

Required environment variable:
  PEONPAD_WARGUS_DATA_DIR   Path to the extracted data.Wargus root
                            (overrides the default of ./data.Wargus)

The source directory must contain:
  scripts/stratagus.lua     Wargus Lua entry point (non-empty file)
  extracted                 Extraction sentinel (non-empty file)
  graphics/                 Sprite and tileset directory
  maps/                     Map directory
  sounds/                   Sound directory

Proprietary installer archives (.mpq, install.exe) and platform metadata
(.DS_Store, Thumbs.db, desktop.ini) are excluded from the staged copy. Symbolic
links are rejected so the staged tree cannot reference content outside it.
inside build/ which is git-ignored; no game assets ever enter tracked paths.

To inject the staged data into a running visionOS simulator app container
after installing the app, run:
  ./scripts/inject-visionos-wargus-data.sh
EOF
}

if (( $# == 1 )) && [[ "$1" == (--help|-h) ]]; then
  usage
  exit 0
fi
if (( $# > 0 )); then
  print -u2 "unexpected argument: $1"
  usage >&2
  exit 2
fi

# ── Validate the source directory ─────────────────────────────────────────────

[[ -d "$SOURCE_DIR" ]] || {
  print -u2 "Wargus data directory not found: $SOURCE_DIR"
  print -u2 "Set PEONPAD_WARGUS_DATA_DIR to the path of your extracted data.Wargus root."
  exit 1
}

for required in scripts/stratagus.lua extracted; do
  [[ -s "$SOURCE_DIR/$required" ]] || {
    print -u2 "invalid extracted Wargus data; missing or empty $required: $SOURCE_DIR"
    exit 1
  }
done
for required in graphics maps sounds; do
  [[ -d "$SOURCE_DIR/$required" ]] || {
    print -u2 "invalid extracted Wargus data; missing directory $required: $SOURCE_DIR"
    exit 1
  }
done

# Refuse to stage from a path inside the repository source tree.
SOURCE_DIR=${SOURCE_DIR:A}
case "$SOURCE_DIR/" in
  "$ROOT_DIR/"*)
    print -u2 "source must be outside the repository: $SOURCE_DIR"
    exit 1
    ;;
esac

SYMLINK_HIT=$(find "$SOURCE_DIR" -type l -print -quit)
[[ -z "$SYMLINK_HIT" ]] || {
  print -u2 "invalid extracted Wargus data; symbolic links are not allowed: $SYMLINK_HIT"
  exit 1
}

# ── Stage to the ignored build directory ──────────────────────────────────────

mkdir -p "$DEST_DIR"
rsync -a --delete --delete-excluded \
  --exclude '*.[Mm][Pp][Qq]' \
  --exclude '[Ii][Nn][Ss][Tt][Aa][Ll][Ll].[Ee][Xx][Ee]' \
  --exclude .DS_Store \
  --exclude Thumbs.db \
  --exclude desktop.ini \
  "$SOURCE_DIR/" "$DEST_DIR/"

# ── Sanity-check the destination ──────────────────────────────────────────────

[[ -s "$DEST_DIR/scripts/stratagus.lua" ]] || {
  print -u2 "staging produced an incomplete destination: $DEST_DIR"
  exit 1
}

# Confirm the build directory is git-ignored so no asset can be committed.
if git -C "$ROOT_DIR" check-ignore -q "$DEST_DIR" 2>/dev/null; then
  : # expected: build/ is in .gitignore
else
  print -u2 "FATAL: staged destination is not git-ignored: $DEST_DIR"
  print -u2 "No game data should ever be committable. Aborting."
  exit 1
fi

print "Staged private Wargus visionOS game data:"
print "  source:  $SOURCE_DIR"
print "  staged:  build/visionos-wargus-data"
print "  note:    proprietary data remains ignored and must not be distributed"
print ""
print "Next step — inject into a running simulator app container:"
print "  ./scripts/inject-visionos-wargus-data.sh"
