#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
SDL3_DIR="$ROOT_DIR/third_party/sdl3"

(
  cd "$SDL3_DIR"
  shasum -a 256 -c SHA256SUMS
)

for archive in "$SDL3_DIR"/sources/*.tar.gz; do
  if tar -tzf "$archive" | grep -Eiq \
      '(^|/)(data\.Wargus|sdl2-compat)(/|$)|\.mpq$|setup_warcraft_ii_|/SDL_syswm\.h$'; then
    print -u2 "forbidden content found in SDL3 archive: ${archive:t}"
    exit 1
  fi
done

print "locked SDL3 source archives verified"
