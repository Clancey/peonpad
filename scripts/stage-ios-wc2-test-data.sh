#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
SOURCE_DIR=${PEONPAD_WC2_DATA_DIR:-$ROOT_DIR/data.Wargus}
DEST_DIR="$ROOT_DIR/build/ios-wc2-data"
DISABLED_DIR="$ROOT_DIR/build/ios-wc2-disabled-modes"
REPLAY_PATCH="$ROOT_DIR/patches/wc2-data/0001-disable-replays-ios-test.patch"

for required in scripts/stratagus.lua extracted; do
  [[ -s "$SOURCE_DIR/$required" ]] || {
    print -u2 "invalid extracted Warcraft II data; missing or empty $required: $SOURCE_DIR"
    exit 1
  }
done
for required in graphics maps sounds; do
  [[ -d "$SOURCE_DIR/$required" ]] || {
    print -u2 "invalid extracted Warcraft II data; missing directory $required: $SOURCE_DIR"
    exit 1
  }
done

SOURCE_DIR=${SOURCE_DIR:A}

mkdir -p "$DEST_DIR" "$DISABLED_DIR"
rsync -a --delete --delete-excluded \
  --exclude install.mpq \
  --exclude .DS_Store \
  --exclude maps/ftm/ \
  --exclude maps/fl/ \
  "$SOURCE_DIR/" "$DEST_DIR/"

for mode in "For the Motherland" "Front Lines" "Random Skirmish"; do
  source_mode="$DEST_DIR/scripts/lists/maps/$mode"
  [[ -f "$source_mode" ]] || continue
  mv -f "$source_mode" "$DISABLED_DIR/$mode"
done

patch -s -p1 -d "$DEST_DIR" < "$REPLAY_PATCH"

print "Staged private Warcraft II iPad test data:"
print "  source:  $SOURCE_DIR"
print "  runtime: build/ios-wc2-data"
print "  modes:   Skirmish Classic, Skirmish Modern, original campaigns"
print "  replay:  hidden until playback is reliable on iPad"
print "  note:    proprietary data remains ignored and must not be distributed"
