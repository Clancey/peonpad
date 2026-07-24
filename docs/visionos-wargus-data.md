# Private Wargus data staging for visionOS

PeonPad's native visionOS shell can load authentic Warcraft II game data from
an already-extracted private copy you own. This document describes the local
developer workflow that keeps proprietary assets strictly outside the repository.

**No proprietary assets are distributed, committed, or bundled with PeonPad.**
You must own a licensed copy of Warcraft II. The scripts here operate only on
data you have already extracted to your own machine.

---

## Prerequisites

- A licensed copy of Warcraft II with data extracted by wartool / Wargus into a
  local `data.Wargus/` directory.
- The native visionOS shell built and installed in an Apple Vision Pro simulator.
  Follow [`visionos-shell.md`](visionos-shell.md) to reach that state.

---

## Opt-in environment variable

All staging and injection is gated behind an explicit environment variable:

```sh
PEONPAD_WARGUS_DATA_DIR=/path/to/your/data.Wargus
```

No personal path is ever hardcoded. When `PEONPAD_WARGUS_DATA_DIR` is unset,
the scripts fall back to `./data.Wargus` inside the repository root — which is
git-ignored and never expected to exist in a normal checkout.

---

## Step 1 — Stage game data

```sh
PEONPAD_WARGUS_DATA_DIR="/path/to/data.Wargus" \
  ./scripts/stage-visionos-wargus-data.sh
```

The script validates that the source directory looks like a plausible extracted
Wargus root (checking for `scripts/stratagus.lua`, the `extracted` sentinel,
and the `graphics/`, `maps/`, and `sounds/` directories) and then copies the
content — excluding proprietary installer archives (`.mpq`, `install.exe`) and
macOS metadata — into:

```
build/visionos-wargus-data/      ← read-only game data, git-ignored
```

`build/` is listed in `.gitignore`; the staged copy can never be accidentally
committed. The script also verifies this invariant explicitly with
`git check-ignore` and aborts if it fails.

---

## Step 2 — Build and install the native shell

```sh
STATE=$(./scripts/visionos-simulator.sh create --label wargus-data)
DETAILS=$(./scripts/visionos-simulator.sh details --state "$STATE")
UDID=${DETAILS%%$'\t'*}
./scripts/build-visionos-shell.sh xrsimulator
./scripts/visionos-simulator.sh install --state "$STATE" --udid "$UDID" \
  --app build/visionos-xrsimulator/PeonPadVisionShell.app
```

This creates an isolated owned Apple Vision Pro and installs the Release native
visionOS shell on its explicit UDID. Use a shell trap to run
`visionos-simulator.sh cleanup --state "$STATE"` if the sequence is interrupted.

---

## Step 3 — Inject staged data into the simulator container

After the app is installed and has created its data container:

```sh
./scripts/inject-visionos-wargus-data.sh --state "$STATE"
```

The script validates the ownership record, resolves the explicit simulator
app-data container, and stages the read-only game data into:

```
<data-container>/Documents/wargus-data/      ← read-only game data
```

It also pre-creates the writable user directory:

```

When finished, terminate the app if launched and delete only the owned device:

```sh
./scripts/visionos-simulator.sh cleanup --state "$STATE"
```

See [`visionos-simulator-automation.md`](visionos-simulator-automation.md) for
the user-simulator opt-in and interactive foreground workflow.
<data-container>/Library/Application Support/org.peonpad.visionos/user/
```

---

## Runtime path contract

| Concern | Path |
|---------|------|
| Read-only game data | `<data-container>/Documents/wargus-data/` |
| Writable user/config/save/log | `<data-container>/Library/Application Support/<bundle-id>/user/` |

The SDL3 engine receives the game-data path as the `-d` argument and the user
path as the `-u` argument. `SDL_GetPrefPath("peonpad", "wargus")` resolves to a
subdirectory of the writable user path under the app container.

When the engine is invoked interactively on macOS (via `run-macos.sh`), the same
argument convention applies with isolated `runtime/macos/<profile>/` directories
rooted at the repository.

---

## Asset-cleanliness guarantee

- `build/` is listed in `.gitignore`. The staged data lives exclusively there.
- `stage-visionos-wargus-data.sh` calls `git check-ignore` and aborts if the
  destination is not ignored.
- The source directory must be **outside** the repository; the script rejects any
  source path inside `$ROOT_DIR/`.
- Proprietary installer archives are excluded from the staged copy via
  `rsync --exclude` patterns.
- `tests/script-guardrails.sh` verifies all of the above invariants with
  synthetic fixtures — no proprietary data is required to run them.

---

## Cleanup

To remove staged data and reset to a clean working tree:

```sh
rm -rf build/visionos-wargus-data
```

`git status` will remain completely clean because `build/` is git-ignored.

---

## Status and forward path

The current native visionOS shell (`org.peonpad.visionos`) is the SDL3 smoke
shell documented in [`visionos-shell.md`](visionos-shell.md). It does not yet
run Stratagus or load a map.

When full gameplay is enabled on visionOS, the CMake build will accept a
`PEONPAD_VISIONOS_DATA_DIR` cache variable (mirroring the existing
`PEONPAD_IOS_DATA_DIR`) and embed the staged data into the app bundle at build
time. Until then, `inject-visionos-wargus-data.sh` provides the runtime path
to the simulator container for integration testing.
