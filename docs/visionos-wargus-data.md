# Private Wargus data staging for visionOS

PeonPad's native visionOS shell can load authentic Warcraft II game data from
an already-extracted private copy you own. This document describes the local
developer workflow that keeps proprietary assets strictly outside the repository.

**No proprietary assets are distributed or committed with PeonPad.** The
default build remains asset-free. An explicit private build mode can embed your
own licensed extracted runtime data into a local app bundle that must not be
shared. You must own a licensed copy of Warcraft II.

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

## Step 2 — Build the tabletop app

```sh
./scripts/build-visionos-tabletop.sh xrsimulator
```

This produces an asset-free app. It can use simulator injection as a development
fallback.

To build a private app that launches normally with its licensed data embedded:

```sh
PEONPAD_WARGUS_DATA_DIR="/path/to/data.Wargus" \
  ./scripts/build-visionos-tabletop.sh xrsimulator --private-data
```

`--private-data` is the only switch that enables embedding, and it requires the
environment variable. The filtered runtime tree is copied to the deterministic,
read-only bundle resource `PrivateGameData/wargus/`. The resulting app can be
hundreds of megabytes; its exact size depends on the extracted edition. It is
for the license holder's local use only and must not be redistributed.

---

## Step 3 — Inject staged data into the simulator container

After the app is installed and has created its data container:

```sh
./scripts/inject-visionos-wargus-data.sh
```

The script locates the Apple Vision Pro simulator, resolves the app's data
container via `simctl get_app_container … data`, and stages the read-only game
data into:

```
<data-container>/Documents/wargus-data/      ← read-only game data
```

It also pre-creates the writable user directory:

```
<data-container>/Library/Application Support/org.peonpad.visionos/user/
```

---

## Runtime path contract

| Concern | Path |
|---------|------|
| Read-only game data (private build, preferred) | `<app>/PrivateGameData/wargus/` |
| Read-only game data (development fallback) | `<data-container>/Documents/wargus-data/` |
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
- Symlinks are rejected, and MPQs/installers/platform metadata are forbidden in
  both private and default bundle verification.
- Default verification fails if `PrivateGameData` exists. Private verification
  only permits a validated runtime tree at `PrivateGameData/wargus`.
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

## Runtime behavior

The tabletop launcher prefers a validated embedded private bundle, then checks
the simulator's injected `Documents/wargus-data` fallback. Writable config,
saves, logs, and caches always remain under Application Support and are passed
to Stratagus with `-u`; the read-only data root is passed with `-d`.
