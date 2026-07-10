#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REF_DIR="$ROOT_DIR/ref"

if [ ! -d "$REF_DIR" ]; then
  echo "reference directory is missing: $REF_DIR" >&2
  exit 1
fi

cd "$ROOT_DIR"

if command -v sha256sum >/dev/null 2>&1; then
  find ref -type d -name .git -prune -o \
    -type f ! -name .DS_Store ! -name .git -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | awk '{print $1}'
elif command -v shasum >/dev/null 2>&1; then
  find ref -type d -name .git -prune -o \
    -type f ! -name .DS_Store ! -name .git -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 \
    | shasum -a 256 \
    | awk '{print $1}'
else
  echo "no SHA-256 implementation found (need sha256sum or shasum)" >&2
  exit 1
fi
