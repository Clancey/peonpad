#!/bin/zsh

set -eu
setopt PIPE_FAIL

SCRIPT_DIR=${0:A:h}
STATE_ROOT=${PEONPAD_VISIONOS_SIMULATOR_STATE_ROOT:-${HOME}/Library/Caches/org.peonpad/simulator-automation}
STATE_ROOT=${STATE_ROOT:A}
SIMCTL_OVERRIDE=${PEONPAD_SIMCTL_BIN:-}
DEVICE_PREFIX="PeonPad Agent "

usage() {
  cat <<'EOF'
Usage: ./scripts/visionos-simulator.sh <command> [options]

Commands:
  create [--label LABEL] [--owner-pid PID]
                                         Create, boot, and verify an owned Vision Pro.
  details --state PATH                   Print UDID, name, runtime, and state.
  assert --udid UDID [target options]    Verify an owned or explicitly opted-in target.
  boot --udid UDID [target options]      Boot and wait for an explicit target.
  install --udid UDID --app PATH [target options]
  uninstall --udid UDID --bundle ID [target options]
  launch --udid UDID --bundle ID [--env NAME=VALUE ...]
         [--stdout PATH] [--stderr PATH] [target options]
  container --udid UDID --bundle ID --kind <app|data> [target options]
  screenshot --udid UDID --output PATH [target options]
  terminate --udid UDID --bundle ID [target options]
  cleanup --state PATH                   Shut down/delete only that owned device.
  reap-stale [--older-than SECONDS]      Safely remove abandoned owned devices.

Target options:
  --state PATH               Ownership metadata returned by create.
  --allow-user-simulator     Explicit opt-in for a user-selected --udid.

Automation should omit --udid initially, call create, and pass its returned
--state and explicit UDID to every later operation. No command accepts "booted".
EOF
}

simctl() {
  if [[ -n "$SIMCTL_OVERRIDE" ]]; then
    "$SIMCTL_OVERRIDE" "$@"
  else
    xcrun simctl "$@"
  fi
}

die() {
  print -u2 -- "$1"
  exit "${2:-1}"
}

valid_udid() {
  print -r -- "$1" |
    grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
}

ensure_state_root() {
  mkdir -p "$STATE_ROOT"
  chmod 700 "$STATE_ROOT"
}

state_path_is_safe() {
  local state=${1:A}
  [[ "$state/" == "$STATE_ROOT/"run.*"/" && "$state:h" == "$STATE_ROOT" ]]
}

metadata_file() {
  print -r -- "$1/ownership.plist"
}

metadata_value() {
  plutil -extract "$2" raw "$(metadata_file "$1")"
}

metadata_value_optional() {
  plutil -extract "$2" raw "$(metadata_file "$1")" 2>/dev/null || :
}

device_record() {
  local udid=$1
  local devices
  devices=$(simctl list devices)
  awk -v id="$udid" '
    index($0, "(" id ")") {print; exit}
  ' <<< "$devices"
}

device_record_by_name() {
  local name=$1
  local devices
  devices=$(simctl list devices)
  awk -v name="$name" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (index(line, name " (") == 1) {
        print line
        exit
      }
    }
  ' <<< "$devices"
}

owned_details() {
  local state=$1
  local requested_udid=${2:-}
  local metadata udid name runtime token record
  state_path_is_safe "$state" ||
    die "ownership state is outside the PeonPad simulator state root"
  metadata=$(metadata_file "$state")
  [[ -f "$metadata" ]] || die "owned simulator metadata is missing: $metadata"
  [[ "$(metadata_value "$state" schema_version)" == 1 ]] ||
    die "owned simulator metadata has an unsupported schema"
  [[ "$(metadata_value "$state" status)" == ready ]] ||
    die "owned simulator creation did not complete"
  udid=$(metadata_value "$state" udid)
  name=$(metadata_value "$state" name)
  runtime=$(metadata_value "$state" runtime)
  token=$(metadata_value "$state" token)
  valid_udid "$udid" || die "owned simulator metadata contains an invalid UDID"
  [[ "$name" == "$DEVICE_PREFIX$token" && -n "$token" ]] ||
    die "owned simulator metadata does not identify a PeonPad agent device"
  if [[ -n "$requested_udid" && "${requested_udid:u}" != "${udid:u}" ]]; then
    die "explicit UDID does not match the owned simulator metadata"
  fi
  record=$(device_record "$udid")
  [[ -n "$record" ]] || die "owned simulator no longer exists: $udid"
  [[ "$record" == *"$name ($udid) ("* ]] ||
    die "simulator name/UDID does not match ownership metadata; refusing access"
  print -r -- "$udid	$name	$runtime	$record"
}

assert_user_target() {
  local udid=$1
  local devices selected
  valid_udid "$udid" || die "explicit simulator UDID is invalid"
  devices=$(simctl list devices available)
  selected=$(awk -v requested="$udid" '
    /^-- visionOS [0-9]+([.][0-9]+)* --$/ {
      in_vision_runtime = 1
      next
    }
    /^-- / {
      in_vision_runtime = 0
      next
    }
    in_vision_runtime &&
      $0 ~ /^[[:space:]]*Apple Vision Pro \([0-9A-Fa-f-]+\) \((Booted|Shutdown)\)[[:space:]]*$/ {
      line = $0
      if (index(toupper(line), "(" toupper(requested) ")")) {
        print requested
        exit
      }
    }
  ' <<< "$devices")
  [[ -n "$selected" ]] ||
    die "explicit simulator is not an available Apple Vision Pro on visionOS"
  [[ "${selected:u}" == "${udid:u}" ]] ||
    die "explicit simulator validation returned a different UDID"
}

assert_target() {
  local state=$1
  local udid=$2
  local allow_user=$3
  [[ "$udid" != booted ]] || die "the ambiguous 'booted' simulator target is forbidden"
  if [[ -n "$state" ]]; then
    owned_details "$state" "$udid" >/dev/null
  elif (( allow_user )); then
    assert_user_target "$udid"
  else
    die "unowned simulator refused; pass --state or explicitly opt in with --allow-user-simulator"
  fi
}

latest_runtime() {
  local runtimes
  runtimes=$(simctl list runtimes available)
  awk '
    function score(version, values, count, part_index, result) {
      count = split(version, values, ".")
      result = 0
      for (part_index = 1; part_index <= 4; part_index++) {
        result = result * 1000 + (part_index <= count ? values[part_index] + 0 : 0)
      }
      return result
    }
    /^visionOS [0-9]+([.][0-9]+)*/ && $0 !~ /unavailable/ {
      version = $2
      current = score(version)
      identifier = $NF
      if (identifier ~ /^com[.]apple[.]CoreSimulator[.]SimRuntime[.]xrOS-/ &&
          (!found || current > best)) {
        found = 1
        best = current
        best_version = version
        best_identifier = identifier
      }
    }
    END {
      if (found) printf "%s\tvisionOS %s\n", best_identifier, best_version
    }
  ' <<< "$runtimes"
}

vision_device_type() {
  local device_types
  device_types=$(simctl list devicetypes)
  awk '
    /^Apple Vision Pro / {
      line = $0
      sub(/^.*[(]/, "", line)
      sub(/[)].*$/, "", line)
      if (line ~ /^com[.]apple[.]CoreSimulator[.]SimDeviceType[.]/) {
        print line
        exit
      }
    }
  ' <<< "$device_types"
}

write_provisional_metadata() {
  local state=$1
  local token=$2
  local name=$3
  local runtime_id=$4
  local runtime_name=$5
  local owner_pid=$6
  local temporary="$state/ownership.plist.tmp.$$"
  plutil -create xml1 "$temporary" &&
    plutil -insert schema_version -integer 1 "$temporary" &&
    plutil -insert status -string creating "$temporary" &&
    plutil -insert token -string "$token" "$temporary" &&
    plutil -insert name -string "$name" "$temporary" &&
    plutil -insert runtime_identifier -string "$runtime_id" "$temporary" &&
    plutil -insert runtime -string "$runtime_name" "$temporary" &&
    plutil -insert owner_pid -integer "$owner_pid" "$temporary" &&
    plutil -insert created_epoch -integer "$(date +%s)" "$temporary" &&
    plutil -insert repository -string "${SCRIPT_DIR:h}" "$temporary" &&
    mv "$temporary" "$(metadata_file "$state")" &&
    chmod 600 "$(metadata_file "$state")"
}

finalize_metadata() {
  local state=$1
  local udid=$2
  local metadata
  metadata=$(metadata_file "$state")
  plutil -insert udid -string "$udid" "$metadata" &&
    plutil -replace status -string ready "$metadata"
}

create_owned() {
  local label=$1
  local owner_pid=$2
  local runtime_details runtime_id runtime_name device_type token name state udid
  ensure_state_root
  runtime_details=$(latest_runtime)
  [[ -n "$runtime_details" ]] ||
    die "no available visionOS simulator runtime is installed"
  IFS=$'\t' read -r runtime_id runtime_name <<< "$runtime_details"
  device_type=$(vision_device_type)
  [[ -n "$device_type" ]] ||
    die "the Apple Vision Pro simulator device type is unavailable"
  token="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}${RANDOM}"
  [[ -z "$label" ]] || token="${token}-${label//[^A-Za-z0-9_.-]/-}"
  name="$DEVICE_PREFIX$token"
  state=$(mktemp -d "$STATE_ROOT/run.XXXXXX")
  chmod 700 "$state"
  if ! write_provisional_metadata "$state" "$token" "$name" "$runtime_id" \
      "$runtime_name" "$owner_pid"; then
    rm -f "$state"/ownership.plist(N) "$state"/ownership.plist.tmp.*(N)
    rmdir "$state" >/dev/null 2>&1 || :
    die "failed to record provisional simulator ownership metadata"
  fi
  PENDING_CREATE_STATE=$state
  if ! udid=$(simctl create "$name" "$device_type" "$runtime_id"); then
    cleanup_owned "$state" >/dev/null 2>&1 || :
    die "failed to create isolated Apple Vision Pro simulator"
  fi
  if ! valid_udid "$udid"; then
    cleanup_owned "$state" >/dev/null 2>&1 || :
    die "simctl create returned an invalid simulator UDID"
  fi
  if ! finalize_metadata "$state" "$udid"; then
    cleanup_owned "$state" >/dev/null 2>&1 || :
    die "failed to record simulator ownership metadata"
  fi
  if ! simctl boot "$udid" ||
      ! simctl bootstatus "$udid" -b >/dev/null ||
      ! owned_details "$state" "$udid" >/dev/null; then
    cleanup_owned "$state" >/dev/null 2>&1 || :
    die "isolated Apple Vision Pro simulator failed to boot"
  fi
  PENDING_CREATE_STATE=""
  print -r -- "$state"
}

cleanup_owned() {
  local state=$1
  local metadata ownership_status udid name token record
  state_path_is_safe "$state" ||
    die "cleanup state is outside the PeonPad simulator state root"
  metadata=$(metadata_file "$state")
  [[ -f "$metadata" ]] || {
    [[ ! -e "$state" ]] && return 0
    die "cleanup refused because ownership metadata is missing"
  }
  [[ "$(metadata_value "$state" schema_version)" == 1 ]] ||
    die "cleanup refused unsupported ownership metadata"
  ownership_status=$(metadata_value "$state" status)
  [[ "$ownership_status" == (creating|ready) ]] ||
    die "cleanup refused unknown ownership metadata status"
  udid=$(metadata_value_optional "$state" udid)
  name=$(metadata_value "$state" name)
  token=$(metadata_value "$state" token)
  [[ -n "$token" && "$name" == "$DEVICE_PREFIX$token" ]] ||
    die "cleanup refused metadata that does not identify a PeonPad agent device"
  if [[ -n "$udid" ]]; then
    valid_udid "$udid" ||
      die "cleanup refused invalid ownership metadata UDID"
    record=$(device_record "$udid")
  else
    [[ "$ownership_status" == creating ]] ||
      die "cleanup refused ready metadata without a UDID"
    record=$(device_record_by_name "$name")
    if [[ -n "$record" ]]; then
      udid=$(sed -E \
        's/^.*\(([0-9A-Fa-f-]{36})\) \((Booted|Shutdown)\).*$/\1/' \
        <<< "$record")
      valid_udid "$udid" ||
        die "cleanup refused a provisional device with an invalid UDID"
    fi
  fi
  if [[ -z "$record" ]]; then
    rm -f "$metadata"
    rmdir "$state"
    return 0
  fi
  [[ "$record" == *"$name ($udid) ("* ]] ||
    die "cleanup refused because simulator identity changed"
  simctl shutdown "$udid" >/dev/null 2>&1 || :
  simctl delete "$udid" ||
    die "failed to delete owned simulator $udid; ownership metadata retained"
  if [[ -n "$(device_record "$udid")" ]]; then
    die "owned simulator still exists after delete; ownership metadata retained"
  fi
  rm -f "$metadata"
  rmdir "$state"
}

cleanup_pending_create() {
  local state=$PENDING_CREATE_STATE
  [[ -n "$state" ]] || return 0
  PENDING_CREATE_STATE=""
  set +e
  cleanup_owned "$state" >/dev/null 2>&1
}

reap_stale() {
  local older_than=$1
  local now state created owner_pid age
  ensure_state_root
  now=$(date +%s)
  for state in "$STATE_ROOT"/run.*(N/); do
    [[ -f "$(metadata_file "$state")" ]] || continue
    created=$(metadata_value "$state" created_epoch 2>/dev/null || print 0)
    owner_pid=$(metadata_value "$state" owner_pid 2>/dev/null || print 0)
    [[ "$created" == <-> && "$owner_pid" == <-> ]] || continue
    age=$(( now - created ))
    (( age >= older_than )) || continue
    if (( owner_pid > 1 )) && kill -0 "$owner_pid" >/dev/null 2>&1; then
      continue
    fi
    cleanup_owned "$state"
  done
}

if (( $# == 1 )) && [[ "$1" == (--help|-h) ]]; then
  usage
  exit 0
fi

COMMAND=${1:-}
[[ -n "$COMMAND" ]] || {
  usage >&2
  exit 2
}
shift

STATE=""
UDID=""
ALLOW_USER=0
APP=""
BUNDLE=""
KIND=""
OUTPUT=""
STDOUT_PATH=""
STDERR_PATH=""
LABEL=""
OWNER_PID=${PPID:-$$}
OLDER_THAN=86400
PENDING_CREATE_STATE=""
typeset -a CHILD_ENV
CHILD_ENV=()

while (( $# > 0 )); do
  case "$1" in
    --state|--udid|--app|--bundle|--kind|--output|--stdout|--stderr|--label|--owner-pid|--older-than|--env)
      (( $# >= 2 )) || die "missing value for $1" 2
      option=$1
      value=$2
      shift 2
      case "$option" in
        --state) STATE=${value:A} ;;
        --udid) UDID=$value ;;
        --app) APP=${value:A} ;;
        --bundle) BUNDLE=$value ;;
        --kind) KIND=$value ;;
        --output) OUTPUT=${value:A} ;;
        --stdout) STDOUT_PATH=${value:A} ;;
        --stderr) STDERR_PATH=${value:A} ;;
        --label) LABEL=$value ;;
        --owner-pid) OWNER_PID=$value ;;
        --older-than) OLDER_THAN=$value ;;
        --env) CHILD_ENV+=("$value") ;;
      esac
      ;;
    --allow-user-simulator)
      ALLOW_USER=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unexpected argument: $1" 2
      ;;
  esac
done

[[ "$OWNER_PID" == <-> && $OWNER_PID -gt 1 ]] ||
  die "--owner-pid must be a process identifier greater than 1" 2
trap cleanup_pending_create EXIT
trap 'cleanup_pending_create; exit 130' INT TERM

case "$COMMAND" in
  create)
    [[ -z "$STATE$UDID$APP$BUNDLE$KIND$OUTPUT" && $ALLOW_USER -eq 0 ]] ||
      die "create accepts only --label and --owner-pid" 2
    create_owned "$LABEL" "$OWNER_PID"
    ;;
  details)
    [[ -n "$STATE" ]] || die "details requires --state" 2
    details=$(owned_details "$STATE")
    IFS=$'\t' read -r owned_udid owned_name owned_runtime record <<< "$details"
    owned_state=Unknown
    [[ "$record" == *"(Booted)"* ]] && owned_state=Booted
    [[ "$record" == *"(Shutdown)"* ]] && owned_state=Shutdown
    print -r -- "$owned_udid	$owned_name	$owned_runtime	$owned_state"
    ;;
  assert)
    [[ -n "$UDID" ]] || die "assert requires --udid" 2
    assert_target "$STATE" "$UDID" "$ALLOW_USER"
    ;;
  boot)
    [[ -n "$UDID" ]] || die "boot requires --udid" 2
    assert_target "$STATE" "$UDID" "$ALLOW_USER"
    record=$(device_record "$UDID")
    if [[ "$record" == *"(Shutdown)"* ]]; then
      simctl boot "$UDID"
    elif [[ "$record" != *"(Booted)"* ]]; then
      die "explicit simulator is not booted or shutdown"
    fi
    simctl bootstatus "$UDID" -b
    ;;
  install)
    [[ -n "$UDID" && -d "$APP" ]] ||
      die "install requires --udid and an existing --app" 2
    assert_target "$STATE" "$UDID" "$ALLOW_USER"
    simctl install "$UDID" "$APP"
    ;;
  uninstall)
    [[ -n "$UDID" && -n "$BUNDLE" ]] ||
      die "uninstall requires --udid and --bundle" 2
    assert_target "$STATE" "$UDID" "$ALLOW_USER"
    simctl uninstall "$UDID" "$BUNDLE"
    ;;
  launch)
    [[ -n "$UDID" && -n "$BUNDLE" ]] ||
      die "launch requires --udid and --bundle" 2
    assert_target "$STATE" "$UDID" "$ALLOW_USER"
    typeset -a prefixed_env
    typeset -a launch_arguments
    prefixed_env=()
    launch_arguments=(launch --terminate-running-process)
    [[ -z "$STDOUT_PATH" ]] || launch_arguments+=("--stdout=$STDOUT_PATH")
    [[ -z "$STDERR_PATH" ]] || launch_arguments+=("--stderr=$STDERR_PATH")
    launch_arguments+=("$UDID" "$BUNDLE")
    for assignment in "${CHILD_ENV[@]}"; do
      [[ "$assignment" =~ '^[A-Za-z_][A-Za-z0-9_]*=' ]] ||
        die "invalid child environment assignment: $assignment" 2
      prefixed_env+=("SIMCTL_CHILD_${assignment}")
    done
    if [[ -n "$SIMCTL_OVERRIDE" ]]; then
      env "${prefixed_env[@]}" "$SIMCTL_OVERRIDE" "${launch_arguments[@]}"
    else
      env "${prefixed_env[@]}" xcrun simctl "${launch_arguments[@]}"
    fi
    ;;
  container)
    [[ -n "$UDID" && -n "$BUNDLE" && "$KIND" == (app|data) ]] ||
      die "container requires --udid, --bundle, and --kind app|data" 2
    assert_target "$STATE" "$UDID" "$ALLOW_USER"
    simctl get_app_container "$UDID" "$BUNDLE" "$KIND"
    ;;
  screenshot)
    [[ -n "$UDID" && -n "$OUTPUT" ]] ||
      die "screenshot requires --udid and --output" 2
    assert_target "$STATE" "$UDID" "$ALLOW_USER"
    simctl io "$UDID" screenshot "$OUTPUT"
    ;;
  terminate)
    [[ -n "$UDID" && -n "$BUNDLE" ]] ||
      die "terminate requires --udid and --bundle" 2
    assert_target "$STATE" "$UDID" "$ALLOW_USER"
    simctl terminate "$UDID" "$BUNDLE"
    ;;
  cleanup)
    [[ -n "$STATE" && -z "$UDID" && $ALLOW_USER -eq 0 ]] ||
      die "cleanup requires only --state" 2
    cleanup_owned "$STATE"
    ;;
  reap-stale)
    [[ "$OLDER_THAN" == <-> ]] ||
      die "--older-than must be a non-negative integer" 2
    reap_stale "$OLDER_THAN"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
