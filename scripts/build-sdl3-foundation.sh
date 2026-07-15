#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
TARGET=macos

if (( $# > 1 )); then
  print -u2 "Usage: ./scripts/build-sdl3-foundation.sh [macos|ios-simulator|xrsimulator]"
  exit 2
fi
if (( $# == 1 )); then
  case "$1" in
    --help)
      print "Usage: ./scripts/build-sdl3-foundation.sh [macos|ios-simulator|xrsimulator]"
      exit 0
      ;;
    macos|ios-simulator|xrsimulator)
      TARGET=$1
      ;;
    *)
      print -u2 "Usage: ./scripts/build-sdl3-foundation.sh [macos|ios-simulator|xrsimulator]"
      exit 2
      ;;
  esac
fi

"$SCRIPT_DIR/verify-sdl3-sources.sh"

BUILD_DIR="$ROOT_DIR/build/sdl3-$TARGET"
CMAKE_ARGS=(
  -DPEONPAD_ENABLE_SDL3=ON
  -DPEONPAD_ENABLE_ENGINE=OFF
  -DBUILD_TESTING=OFF
  -DCMAKE_BUILD_TYPE=Release
)

case "$TARGET" in
  macos)
    CMAKE_ARGS+=(
      -DCMAKE_OSX_ARCHITECTURES=arm64
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
    )
    ;;
  ios-simulator)
    CMAKE_ARGS+=(
      -DCMAKE_TOOLCHAIN_FILE="$ROOT_DIR/cmake/toolchains/ios-simulator-arm64.cmake"
    )
    ;;
  xrsimulator)
    CMAKE_ARGS+=(
      -DCMAKE_TOOLCHAIN_FILE="$ROOT_DIR/cmake/toolchains/xros-simulator-arm64.cmake"
    )
    ;;
esac

cmake -E remove_directory "$BUILD_DIR"
cmake --fresh -S "$ROOT_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
  "${CMAKE_ARGS[@]}"
cmake --build "$BUILD_DIR" --parallel

if [[ "$TARGET" == macos ]]; then
  BINARY="$BUILD_DIR/peonpad_sdl3_smoke"
else
  BINARY="$BUILD_DIR/peonpad_sdl3_smoke.app/peonpad_sdl3_smoke"
fi
[[ -x "$BINARY" ]] || {
  print -u2 "missing SDL3 foundation executable: $BINARY"
  exit 1
}

case "$TARGET" in
  macos)
    file "$BINARY" | grep -q 'arm64'
    "$BINARY" --headless
    "$BINARY"
    ;;
  ios-simulator)
    otool -l "$BINARY" | awk '
      $1 == "platform" {count++; if ($2 != 7) bad = 1}
      END {exit count == 0 || bad}
    '
    ;;
  xrsimulator)
    otool -l "$BINARY" | awk '
      $1 == "platform" {count++; if ($2 != 12) bad = 1}
      END {exit count == 0 || bad}
    '
    ;;
esac

print "PeonPad direct SDL3 foundation built: $TARGET"
