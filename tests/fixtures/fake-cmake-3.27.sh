#!/bin/sh

set -eu

if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  printf 'cmake version 3.27.9\n'
  exit 0
fi

printf 'unexpected fake CMake arguments: %s\n' "$*" >&2
exit 2
