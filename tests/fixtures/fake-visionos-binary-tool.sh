#!/bin/zsh

set -eu

case "${0:t}" in
  lipo)
    [[ "$1" == -archs ]] || exit 2
    print arm64
    ;;
  otool)
    case "$1" in
      -l)
        cat <<EOF
Load command 1
      cmd LC_BUILD_VERSION
 platform ${PEONPAD_TEST_MACHO_PLATFORM:-12}
    minos ${PEONPAD_TEST_MACHO_MINIMUM:-2.0}
      sdk ${PEONPAD_TEST_MACHO_SDK:-26.5}
EOF
        ;;
      -L)
        [[ -z "${PEONPAD_TEST_OTOOL_L_FAIL:-}" ]] || exit 71
        print "$2:"
        print "\t/System/Library/Frameworks/UIKit.framework/UIKit (compatibility version 1.0.0, current version 1.0.0)"
        if [[ -n "${PEONPAD_TEST_EMBEDDED_DEPENDENCY:-}" \
            && "$2" != */Frameworks/Fake.framework/Fake ]]; then
          print "\t@rpath/Fake.framework/Fake (compatibility version 1.0.0, current version 1.0.0)"
        fi
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  find)
    if [[ -n "${PEONPAD_TEST_FIND_FRAMEWORKS_FAIL:-}" \
        && "$1" == */Frameworks ]]; then
      exit 71
    fi
    exec /usr/bin/find "$@"
    ;;
  xcrun)
    [[ "$1" == assetutil && "$2" == --info && -f "$3" ]] || exit 2
    cat <<EOF
[
  {
    "AssetType" : "SolidImageStack",
    "Name" : "${PEONPAD_TEST_COMPILED_ICON:-AppIcon}"
  }
]
EOF
    ;;
  codesign)
    case "$1" in
      --verify)
        [[ "${PEONPAD_TEST_CODESIGN_MODE:-adhoc}" != unsigned ]]
        ;;
      -dvv)
        print -u2 "Signature=adhoc"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
