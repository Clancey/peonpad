# visionOS simulator isolation

PeonPad automation must never select `booted`, reuse whichever Simulator happens
to be active, foreground Simulator, or shut down/delete a device it did not
create. `scripts/visionos-simulator.sh` is the single simulator ownership and
targeting contract for automated visionOS work.

## Default automated workflow

These commands create a uniquely named `PeonPad Agent ...` Apple Vision Pro,
record ownership metadata, boot and verify that exact UDID, run against it, and
terminate the app and delete only that owned device on exit:

```sh
./scripts/build-visionos-shell.sh xrsimulator --launch
./scripts/build-visionos-tabletop.sh xrsimulator --launch \
  --screenshot /tmp/peonpad-tabletop.png
./scripts/accept-visionos.sh xrsimulator
```

Automation does not open or foreground Simulator. Screenshots and recordings
remain limited by the visionOS Simulator compositor and neutral persona pose;
they are evidence of that compositor output, not a substitute for interactive
inspection.

Ownership records live under
`~/Library/Caches/org.peonpad/simulator-automation/run.*` by default. Each record
contains the unique device name, UDID, runtime, creation time, and owner PID.
Cleanup revalidates the exact name/UDID pair before issuing shutdown or delete.
If deletion fails, the record is retained so a later cleanup can retry safely:

```sh
./scripts/visionos-simulator.sh cleanup --state /path/to/run.state
./scripts/visionos-simulator.sh reap-stale --older-than 86400
```

`reap-stale` considers only PeonPad ownership records older than the threshold
whose recorded owner PID is no longer live. It still performs the same exact
name/UDID validation. Concurrent runs use separate state directories and unique
device names.

## Child environment and Wargus data

The manager converts each `--env NAME=VALUE` to a process-scoped
`SIMCTL_CHILD_NAME=VALUE` assignment. This is required because supported
`simctl` versions do not provide `launch --setenv`. Nothing is exported into a
different launch:

```sh
./scripts/build-visionos-tabletop.sh xrsimulator --launch \
  --inject-wargus-data \
  --child-env PEONPAD_TABLETOP_COMMAND_HARNESS=1 \
  --child-env PEONPAD_TABLETOP_ACCEPTANCE_HOLD=1 \
  --child-env 'PEONPAD_TABLETOP_SCENARIO=maps/scenario/A Tight Spot BNE.pud.smp.gz' \
  --screenshot /tmp/peonpad-tabletop-harness.png
```

Install, app-container lookup, data injection, launch, termination, and
screenshot commands always receive an explicit UDID plus either ownership state
or the user-device opt-in. Automated build scripts terminate their bundle before
cleanup, so command harnesses and accessibility/input interception cannot linger.

For a manually managed owned device:

```sh
STATE=$(./scripts/visionos-simulator.sh create --label local-test)
DETAILS=$(./scripts/visionos-simulator.sh details --state "$STATE")
UDID=${DETAILS%%$'\t'*}

./scripts/visionos-simulator.sh install \
  --state "$STATE" --udid "$UDID" --app /path/to/PeonPadTabletop.app
PEONPAD_VISIONOS_BUNDLE_IDENTIFIER=org.peonpad.visionos.tabletop \
  ./scripts/inject-visionos-wargus-data.sh --state "$STATE"
./scripts/visionos-simulator.sh launch \
  --state "$STATE" --udid "$UDID" \
  --bundle org.peonpad.visionos.tabletop
./scripts/visionos-simulator.sh cleanup --state "$STATE"
```

Use a shell trap around manual sequences so interruption also invokes cleanup.

## Explicit user simulator opt-in

Reusing a user-created simulator is never the default. It requires the exact
UDID and `--allow-user-simulator` on every entry point:

```sh
./scripts/build-visionos-tabletop.sh xrsimulator --launch \
  --simulator-udid <UDID> --allow-user-simulator
```

The legacy `PEONPAD_VISION_SIMULATOR_UDID` override is still recognized, but now
also requires `PEONPAD_VISIONOS_ALLOW_USER_SIMULATOR=1`. This intentionally
prevents unattended code from inheriting a UDID and taking over an active
simulator. User simulators are never shut down or deleted by PeonPad; the
launched PeonPad bundle is terminated when automation exits.

Interactive use is separate. Foreground only the simulator the user chose:

```sh
./scripts/open-visionos-simulator.sh <UDID>
```

That helper validates the explicit Apple Vision Pro UDID, then runs
`open -a Simulator --args -CurrentDeviceUDID <UDID>`. Automated scripts must not
call it.
