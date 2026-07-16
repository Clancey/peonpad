#!/bin/sh

set -eu

if [ "$#" -ne 6 ]; then
  echo "usage: $0 <sdk> <cmake> <app> <catalog> <source icon> <work dir>" >&2
  exit 64
fi

SDK=$1
CMAKE_COMMAND=$2
APP=$3
CATALOG=$4
SOURCE_ICON=$5
WORK_DIR=$6
GENERATED_CATALOG="$WORK_DIR/PeonPadAssets.xcassets"

case "$SDK" in
  xrsimulator|*XRSimulator*) PLATFORM=xrsimulator ;;
  xros|*XROS*) PLATFORM=xros ;;
  *)
    echo "unsupported visionOS SDK: $SDK" >&2
    exit 1
    ;;
esac

[ -d "$APP" ] || {
  echo "missing visionOS app bundle: $APP" >&2
  exit 1
}
[ -d "$CATALOG" ] || {
  echo "missing visionOS asset catalog: $CATALOG" >&2
  exit 1
}
[ -f "$SOURCE_ICON" ] || {
  echo "missing legal PeonPad source icon: $SOURCE_ICON" >&2
  exit 1
}

"$CMAKE_COMMAND" -E rm -rf "$WORK_DIR"
"$CMAKE_COMMAND" -E make_directory "$WORK_DIR"
"$CMAKE_COMMAND" -E copy_directory "$CATALOG" "$GENERATED_CATALOG"

for layer in Front Back; do
  "$CMAKE_COMMAND" -E copy_if_different "$SOURCE_ICON" \
    "$GENERATED_CATALOG/AppIcon.solidimagestack/$layer.solidimagestacklayer/Content.imageset/PeonPadIcon.png"
done

xcrun --sdk "$PLATFORM" actool \
  --compile "$APP" \
  --platform "$PLATFORM" \
  --minimum-deployment-target 2.0 \
  --target-device vision \
  --app-icon AppIcon \
  --output-partial-info-plist "$WORK_DIR/asset-info.plist" \
  "$GENERATED_CATALOG"

[ -f "$APP/Assets.car" ] || {
  echo "visionOS asset compiler did not produce Assets.car" >&2
  exit 1
}
[ "$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon raw \
  "$WORK_DIR/asset-info.plist")" = "AppIcon" ] || {
  echo "visionOS asset compiler did not recognize AppIcon" >&2
  exit 1
}

# Finder and cloud-backed folders can attach metadata rejected by signing.
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP"
  xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP" 2>/dev/null || true
fi
