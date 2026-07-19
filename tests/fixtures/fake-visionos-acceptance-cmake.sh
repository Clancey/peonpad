#!/bin/zsh

set -eu

if [[ "$1" == --version ]]; then
  print "cmake version 4.3.1"
  exit 0
fi
if [[ "$1" == -E ]]; then
  exec "${PEONPAD_TEST_REAL_CMAKE:?}" "$@"
fi
print -u2 "unexpected fake cmake invocation: $*"
exit 2
