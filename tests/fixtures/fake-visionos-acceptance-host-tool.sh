#!/bin/zsh

set -eu

case "${0:t}" in
  git)
    is_status=0
    for argument in "$@"; do
      [[ "$argument" == status ]] && is_status=1
    done
    if (( is_status )); then
      case "${PEONPAD_TEST_GIT_DIRTY_MODE:-}" in
        "") ;;
        unstaged) print ' M tests/fixtures/source.cpp' ;;
        staged) print 'M  tests/fixtures/source.cpp' ;;
        untracked) print '?? tests/fixtures/untracked.cpp' ;;
        *) exit 2 ;;
      esac
      exit 0
    fi
    exec "${PEONPAD_TEST_REAL_GIT:?}" "$@"
    ;;
  plutil)
    output=""
    want_output=0
    for argument in "$@"; do
      if (( want_output )); then
        output=$argument
        want_output=0
      elif [[ "$argument" == -o ]]; then
        want_output=1
      fi
    done
    if [[ "$output" == *.json.<-> ]]; then
      case "${PEONPAD_TEST_RESULT_FAILURE:-}" in
        conversion) exit 71 ;;
        invalid-conversion)
          print '{invalid' > "$output"
          exit 0
          ;;
      esac
    fi
    exec /usr/bin/plutil "$@"
    ;;
  mv)
    destination=${@[-1]}
    if [[ -n "${PEONPAD_TEST_RESULT_FAILURE:-}" ]]; then
      case "${PEONPAD_TEST_RESULT_FAILURE:-}" in
        move) exit 71 ;;
        invalid-move)
          print '{invalid' > "$destination"
          rm -f "$1"
          exit 0
          ;;
      esac
    fi
    exec /bin/mv "$@"
    ;;
  *)
    exit 2
    ;;
esac
