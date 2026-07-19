#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 <directory>" >&2
  exit 64
fi

tree_root=$(cd "$1" && pwd)
repo_root=$(git -C "$tree_root" rev-parse --show-toplevel)

case "$tree_root/" in
  "$repo_root"/*) ;;
  *)
    echo "Directory is outside the current Git worktree: $tree_root" >&2
    exit 65
    ;;
esac

tree_path=${tree_root#"$repo_root"/}

git -C "$repo_root" ls-files -z -- "$tree_path" |
  while IFS= read -r -d '' tracked_path; do
    path="$repo_root/$tracked_path"
    relative_path=${tracked_path#"$tree_path"/}
    if [[ ! -f "$path" && ! -L "$path" ]]; then
      echo "Tracked path is missing from the tree: $tracked_path" >&2
      exit 1
    fi
    if [[ -L "$path" ]]; then
      printf 'link\0%s\0%s\0' "$relative_path" "$(readlink "$path")"
    else
      executable=0
      [[ -x "$path" ]] && executable=1
      printf 'file\0%s\0%s\0%s\0' \
        "$relative_path" "$executable" \
        "$(shasum -a 256 "$path" | awk '{print $1}')"
    fi
  done |
  shasum -a 256 |
  awk '{print $1}'
