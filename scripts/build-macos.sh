#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
BUILD_DIR=${PEONPAD_MACOS_BUILD_DIR:-$ROOT_DIR/build/macos}
BUILD_DIR=${BUILD_DIR:A}
JOBS=${PEONPAD_BUILD_JOBS:-8}
MODE=public

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--maintainer" ]]; }; then
  print -u2 "Usage: ./scripts/build-macos.sh [--maintainer]"
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
  START_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
  [[ "$START_DIGEST" == "$EXPECTED_DIGEST" ]] || {
    print -u2 "ref/ does not match config/inputs.lock; refusing to build"
    exit 1
  }
fi

for marker in \
  "$ROOT_DIR/engine/stratagus/.peonpad-source-revision" \
  "$ROOT_DIR/game/wargus/.peonpad-source-revision"; do
  [[ -f "$marker" ]] || {
    print -u2 "staged source marker is missing: ${marker#$ROOT_DIR/}"
    exit 1
  }
done

case "$BUILD_DIR/" in
  "$ROOT_DIR/build/"*) ;;
  *)
    print -u2 "macOS build directory must be inside $ROOT_DIR/build: $BUILD_DIR"
    exit 1
    ;;
esac

# ExternalProject caches preserve absolute source paths, so reset the
# script-owned tree before configuring a checkout in a new location.
cmake -E remove_directory "$BUILD_DIR"

cmake --fresh -S "$ROOT_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
  -DPEONPAD_ENABLE_ENGINE=ON \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DPEONPAD_MACOS_ARCHITECTURE=arm64 \
  -DPEONPAD_MACOS_DEPLOYMENT_TARGET=13.0

cmake --build "$BUILD_DIR" --target peonpad_macos -j "$JOBS"

STRATAGUS="$BUILD_DIR/stratagus"
WARGUS="$BUILD_DIR/wargus/wargus"
WARTOOL="$BUILD_DIR/wargus/wartool"
PUDCONVERT="$BUILD_DIR/wargus/pudconvert"
APP_EXECUTABLE="$BUILD_DIR/PeonPad.app/Contents/MacOS/PeonPad"

for binary in \
  "$STRATAGUS" "$WARGUS" "$WARTOOL" "$PUDCONVERT" "$APP_EXECUTABLE"; do
  [[ -x "$binary" ]] || {
    print -u2 "expected executable was not built: $binary"
    exit 1
  }
  file "$binary" | grep -q 'arm64' || {
    print -u2 "expected arm64 executable: $binary"
    exit 1
  }
  if otool -L "$binary" | grep -Fq "$ROOT_DIR/ref/"; then
    print -u2 "built executable links into immutable ref/: $binary"
    exit 1
  fi
done

if [[ "$MODE" == maintainer ]]; then
  END_DIGEST=$($SCRIPT_DIR/reference-digest.sh)
  [[ "$END_DIGEST" == "$START_DIGEST" ]] || {
    print -u2 "FATAL: ref/ changed during the macOS build"
    exit 70
  }
fi

print "PeonPad macOS baseline built successfully:"
print "  engine:    $STRATAGUS"
print "  launcher:  $WARGUS"
print "  extractor: $WARTOOL"
print "  converter: $PUDCONVERT"
print "  app:       $BUILD_DIR/PeonPad.app"
if [[ "$MODE" == maintainer ]]; then
  print "  reference: unchanged ($END_DIGEST)"
fi
