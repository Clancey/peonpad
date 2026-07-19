#!/bin/zsh

set -eu

[[ "$*" == -version ]] || exit 2
print "Xcode 26.6"
print "Build version 17F113"
