#!/bin/zsh

set -eu

DATA_PATH=""
USER_PATH=""

while (( $# > 0 )); do
  case "$1" in
    -d)
      DATA_PATH=$2
      shift 2
      ;;
    -u)
      USER_PATH=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -d "$DATA_PATH" ]] || {
  print -u2 "fake engine did not receive a readable -d path"
  exit 1
}
[[ -d "$USER_PATH" ]] || {
  print -u2 "fake engine did not receive an isolated -u path"
  exit 1
}

cat > "$USER_PATH/fake-engine-observation.txt" <<EOF
data=$DATA_PATH
user=$USER_PATH
home=$HOME
cache=$XDG_CACHE_HOME
tmp=$TMPDIR
EOF

print "fake Stratagus accepted isolated data and user paths"

