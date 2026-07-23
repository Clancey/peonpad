#!/bin/zsh

# Builds the native visionOS engine static libraries (Stratagus + Wargus
# data-capable engine, SDL3 family, and vendored media libs) with the live
# tabletop bridge compiled in (PEONPAD_TABLETOP). The resulting
# libstratagus_lib.a exports the bridge C ABI and the stratagusMain entry that
# the visionOS tabletop app links against.
#
# The macOS baseline must be built first (./scripts/build-macos.sh) so a host
# tolua++ generator is available for the cross-compile.

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
ROOT_DIR=${SCRIPT_DIR:h}
JOBS=${PEONPAD_BUILD_JOBS:-8}

usage() {
  cat <<'EOF'
Usage: ./scripts/build-visionos-engine-libs.sh <xrsimulator|xros>

Cross-compiles the Stratagus/Wargus engine and SDL3-family static libraries for
the given visionOS target, with the live tabletop bridge hooks compiled in.
Requires ./scripts/build-macos.sh to have produced the host tolua++ generator.
EOF
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# != 1 )); then
  usage >&2
  exit 2
fi

TARGET=$1
case "$TARGET" in
  xrsimulator) TOOLCHAIN="$ROOT_DIR/cmake/toolchains/xros-simulator-arm64.cmake" ;;
  xros)        TOOLCHAIN="$ROOT_DIR/cmake/toolchains/xros-arm64.cmake" ;;
  *) usage >&2; exit 2 ;;
esac

BUILD_DIR=${PEONPAD_VISIONOS_ENGINE_BUILD_DIR:-$ROOT_DIR/build/visionos-$TARGET-engine}
BUILD_DIR=${BUILD_DIR:A}
case "$BUILD_DIR/" in
  "$ROOT_DIR/build/"*) ;;
  *)
    print -u2 "engine build directory must be inside $ROOT_DIR/build"
    exit 1
    ;;
esac

xcrun --sdk "$TARGET" --show-sdk-path >/dev/null || {
  print -u2 "$TARGET SDK is unavailable"
  exit 1
}

cmake -S "$ROOT_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPEONPAD_ENABLE_ENGINE=ON \
  -DPEONPAD_ENABLE_SDL3=ON \
  -DPEONPAD_ENABLE_TABLETOP=ON \
  -DBUILD_TESTING=OFF

cmake --build "$BUILD_DIR" --target stratagus_lib -j "$JOBS"

ENGINE_ARCHIVE="$BUILD_DIR/engine/libstratagus_lib.a"
[[ -f "$ENGINE_ARCHIVE" ]] || {
  print -u2 "engine archive was not produced: $ENGINE_ARCHIVE"
  exit 1
}
lipo -info "$ENGINE_ARCHIVE" | grep -q 'arm64' || {
  print -u2 "engine archive is not arm64: $ENGINE_ARCHIVE"
  exit 1
}
# The bridge capture symbols must be present (built with PEONPAD_TABLETOP).
nm "$ENGINE_ARCHIVE" 2>/dev/null | grep -q '_peonpad_tabletop_publish_snapshot' || {
  print -u2 "engine archive is missing the tabletop bridge symbols"
  exit 1
}

print "PeonPad visionOS engine libraries built ($TARGET):"
print "  engine:  $ENGINE_ARCHIVE"
print "  build:   $BUILD_DIR"
