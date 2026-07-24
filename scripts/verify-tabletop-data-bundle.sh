#!/bin/zsh

set -eu
setopt PIPE_FAIL

usage() {
  print "Usage: ./scripts/verify-tabletop-data-bundle.sh <app> <default|private>"
}

if (( $# == 1 )) && [[ "$1" == --help ]]; then
  usage
  exit 0
fi
if (( $# != 2 )); then
  usage >&2
  exit 2
fi

APP=${1:A}
MODE=$2
PRIVATE_CONTAINER="$APP/PrivateGameData"
PRIVATE_ROOT="$PRIVATE_CONTAINER/wargus"

[[ -d "$APP" ]] || {
  print -u2 "missing tabletop application bundle: $APP"
  exit 1
}
[[ "$MODE" == default || "$MODE" == private ]] || {
  usage >&2
  exit 2
}

SYMLINK_HIT=$(find "$APP" -type l -print -quit)
[[ -z "$SYMLINK_HIT" ]] || {
  print -u2 "symbolic links are forbidden in the tabletop bundle: ${SYMLINK_HIT#$APP/}"
  exit 1
}

FORBIDDEN_HIT=$(find "$APP" -type f \
  \( -iname '*.mpq' -o -iname 'INSTALL.EXE' \
  -o -iname 'setup_warcraft_ii_*' -o -iname '.DS_Store' \
  -o -iname 'Thumbs.db' -o -iname 'desktop.ini' \
  -o -iname '.env' -o -iname '.env.*' \
  -o -iname '*.mobileprovision' -o -iname '*.provisionprofile' \
  -o -iname '*.p12' -o -iname '*.cer' \
  -o -iname '*.keychain' -o -iname '*.keychain-db' \) -print -quit)
[[ -z "$FORBIDDEN_HIT" ]] || {
  print -u2 "forbidden installer, metadata, or credential content in bundle: ${FORBIDDEN_HIT#$APP/}"
  exit 1
}

if [[ "$MODE" == default ]]; then
  [[ ! -e "$PRIVATE_CONTAINER" ]] || {
    print -u2 "private game data leaked into an asset-free default bundle"
    exit 1
  }
  print "verified asset-free tabletop data mode"
  exit 0
fi

[[ -d "$PRIVATE_ROOT" ]] || {
  print -u2 "explicit private mode is missing PrivateGameData/wargus"
  exit 1
}
UNEXPECTED=$(find "$PRIVATE_CONTAINER" -mindepth 1 -maxdepth 1 ! -name wargus -print -quit)
[[ -z "$UNEXPECTED" ]] || {
  print -u2 "unexpected content beside private data root: ${UNEXPECTED#$APP/}"
  exit 1
}
for required in scripts/stratagus.lua extracted; do
  [[ -s "$PRIVATE_ROOT/$required" ]] || {
    print -u2 "embedded private data is missing or empty: $required"
    exit 1
  }
done
for required in graphics maps sounds; do
  [[ -d "$PRIVATE_ROOT/$required" ]] || {
    print -u2 "embedded private data is missing directory: $required"
    exit 1
  }
done

print "verified explicit private tabletop data mode"
print "  data: PrivateGameData/wargus"
