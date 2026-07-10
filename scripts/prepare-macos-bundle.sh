#!/bin/zsh

set -eu

(( $# == 1 )) || {
  print -u2 "usage: prepare-macos-bundle.sh PATH.app"
  exit 2
}

APP_PATH=$1
[[ -d "$APP_PATH/Contents" ]] || {
  print -u2 "not an application bundle: $APP_PATH"
  exit 1
}

# This development artifact is intentionally unsigned. Xcode will own signing
# for device/app distribution; keeping the baseline wrapper unsigned also
# avoids cloud-backed workspaces invalidating an ad-hoc signature by attaching
# Finder metadata to the bundle root.
codesign --remove-signature "$APP_PATH" 2>/dev/null || true
xattr -cr "$APP_PATH"
xattr -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
