# Warcraft II on iPad — Build and Release Plan

*Prepared July 10, 2026. Companion to `warcraft2-ipados-feasibility.md`. This is the execution plan: how to build the port on Chris's hardware, structure the GitHub repo, hand the work to a Codex agent, and release it. Tailored to the confirmed setup below.*

---

## Confirmed setup and corrected mental model

**What gets built:** the open-source Stratagus/Wargus engine (GPLv2 C++), plus a new iOS arm64 target that does not exist yet. Codex writes that target first; there is no pre-existing iPad app to "just compile."

**What does not get built:** the Warcraft II game data. Blizzard never released the WC2 engine source. Your licensed asset files are *extracted* on the desktop into a `data.Wargus` folder and loaded at runtime. The build itself needs zero Blizzard files.

**Two playable paths:**
1. **Free path:** ship the original, libre-licensed **Aleona's Tales** asset set inside the app. Playable on first launch with no Blizzard content and no import step.
2. **Bring-your-own-WC2 path:** extract your Battle.net Edition v2.02 data on the Mac, transfer `data.Wargus` to the iPad, import via Files. This is the "real Warcraft II" experience.

**Your hardware and accounts:**

| Item | Confirmed | Plan implication |
|---|---|---|
| iPad | M2 iPad Pro + Apple Pencil (2nd gen) | Full target device. Pencil hover and barrel double-tap available; squeeze/barrel-roll are M4 Pencil Pro only, treated as optional later-hardware features |
| Mac | macOS with Xcode + CMake (assumed) | Build host, code signer, and desktop extraction machine |
| Apple account | Free Apple ID to start | Enough to build and run on your own iPad. 7-day signing expiry is a non-issue while you rebuild from Xcode during active dev. Upgrade to the $99 Developer Program only at the TestFlight/share milestone |
| WC2 data | Battle.net Edition v2.02 | Cleanest extraction path: wartool + StormLib read `INSTALL.MPQ` / `INSTALL.EXE` directly |

**The build-and-run loop on your machines:** clone the repo on the Mac. Cross-compile SDL2 and the other dependencies for iOS arm64. Xcode signs the app with your free Apple ID and deploys it to the M2 iPad over USB. Iterate. A macOS build target runs on the Mac itself for fast inner-loop iteration; the iPad is for touch, Pencil, and real-performance testing. Data extraction happens on the Mac (wartool against your BNE v2.02), producing `data.Wargus`, which you transfer to the iPad. Extraction is not a build input.

---

## Architecture at a glance

```
GitHub repo (public, GPLv2)
├── engine source (Stratagus/Wargus fork + new iOS target)
├── Aleona's Tales free assets (libre, bundled in-app)
├── iOS Xcode project + CMake iOS toolchain
├── README: 5-minute free-play install
├── docs/BRING-YOUR-OWN-WC2.md: desktop extraction + Files import
└── Releases: prebuilt .ipa (SideStore source) [added later]

NEVER in the repo: any Blizzard asset, any extracted data.Wargus,
any "Warcraft II" branding in the app name/icon.

User's Mac                         User's iPad (M2)
├── clone + build (Xcode)   USB    ├── app (signed with their Apple ID)
├── sign with own Apple ID ──────► ├── plays Aleona's Tales immediately
└── extract own WC2 data           └── imports data.Wargus via Files (optional)
        │  (wartool)                        ▲
        └── data.Wargus ────────────────────┘  (AirDrop / Files / USB-C)
```

The user signing with their own Apple ID is not just a mechanics detail. It is the legal firewall: you distribute source and (later) an unsigned/notarizable binary, they build and sign, so you never ship a running Blizzard-derived product and never touch their assets.

---

## Phased engineering plan

Each phase has a single acceptance test. Do not advance until it passes. Phases 0 to 2 prove the risky, cheap things first; input and polish come after there is something on screen.

### Phase 0 — Desktop baseline and extraction proof (do this first, today)
Before any iOS work, validate the two riskiest cheap things on the Mac.
- Build desktop Wargus from the `Wargus/stratagus` + `Wargus/wargus` master branches on the Mac.
- Extract your BNE v2.02 into `data.Wargus`. Note: the built-in extractor is currently buggy on macOS; use the third-party `shinra-electric/Stratagus-Data-Extractor-Script` if needed.
- Confirm Aleona's Tales runs in the same desktop build with no Blizzard data.
- **Acceptance:** a real WC2 skirmish runs on the Mac from your extracted data, and an Aleona's Tales match runs with no Blizzard data. If either fails, stop and fix before touching iOS.

### Phase 1 — iOS build bring-up
- Add `cmake/toolchains/ios-arm64.cmake` (based on `leetal/ios-cmake`).
- Cross-compile SDL2, SDL2_image, SDL2_mixer, Lua 5.1, tolua++, zlib/png/ogg/vorbis for iOS arm64 static libs. Use the engine's existing `BUILD_VENDORED_SDL` / `BUILD_VENDORED_LUA` paths.
- Mine `Northfear/stratagus-vita` as the reference ARM/SDL2 port; lift its platform abstractions behind a new `TARGET_IOS` define.
- **Acceptance:** `libstratagus` and the Wargus data-layer compile cleanly for iOS arm64. No app yet.

### Phase 2 — First playable on device
- Create a minimal Metal-backed SDL2 Xcode app target. Correct Info.plist: `UIApplicationSupportsIndirectInputEvents = YES`, orientation, launch screen.
- Rework `Parameters::SetDefaultUserDirectory` for iOS to write into the app container via `SDL_GetPrefPath` / `NSDocumentDirectory`. Make all data paths container-relative.
- Bundle Aleona's Tales in-app.
- **Acceptance:** the app launches on your M2 iPad, boots to the Stratagus menu, and plays an Aleona's Tales match with zero Blizzard data and zero import step. This is the vertical slice and the core of the demo.

### Phase 3 — Input: touch, Pencil, hardware pointer
- Map `SDL_FINGER` events to the control scheme: tap-select, drag box-select, two-finger pan, long-press = right-click command, minimap tap/scrub. Enlarge command-grid hit targets to 44 pt.
- Apple Pencil (2nd gen): precise select, drag-select, hold-to-command, precise building placement, hover preview, barrel double-tap for the command radial / attack-move toggle. (No squeeze; that is M4 Pencil Pro.)
- Magic Keyboard hotkeys and trackpad/mouse parity via SDL keyboard/mouse events.
- **Acceptance:** a full skirmish is playable by touch alone, sharper by Pencil, and desktop-equivalent with a Magic Keyboard.

### Phase 4 — Bring-your-own-WC2 and polish
- Implement `UIDocumentPicker` import of a desktop-prepared `data.Wargus` folder into the container; validate and register it alongside Aleona's Tales.
- Profile and fix the Vita-style 1 to 2 minute load; cache converted assets. Verify SDL2_mixer OGG playback and XMI to MID music. Confirm save/load round-trips into the container.
- Disable multiplayer for v1.
- **Acceptance:** you import your extracted BNE v2.02 data on the iPad and play real Warcraft II campaigns and skirmishes; loads and saves are acceptable.

### Phase 5 — Package, release, demo
- Publish the repo with both install flows documented.
- Add a prebuilt `.ipa` to GitHub Releases as a SideStore source.
- Decide on TestFlight (triggers the $99 account).
- Record the native-not-emulation demo video (see feasibility report Section 7): Airplane Mode on, Aleona's Tales campaign, Pencil precision, Magic Keyboard hotkeys, FPS overlay, optional `data.Wargus` import on camera.
- **Acceptance:** a stranger with a Mac and an iPad can follow the README and get to a playable Aleona's Tales match; the demo video is cut.

---

## GitHub repo: the "download and install" model

This is the release vehicle you described. It works, with the discipline that the repo carries the engine and the free assets, never Blizzard data, and never "Warcraft II" branding.

**Repo contents:** the engine fork, the iOS Xcode project and CMake toolchain, the bundled Aleona's Tales assets, a top-level README for the 5-minute free-play path, and `docs/BRING-YOUR-OWN-WC2.md` for the extraction-and-import path. A `NOTICE` file states GPLv2 and that the project ships no Blizzard content.

**README flow A (free, lead with this):**
1. Install AltStore/SideStore, or open the Xcode project.
2. Build and sign with your own Apple ID, deploy to your iPad. (Or install the Releases `.ipa` via SideStore.)
3. Launch. Play Aleona's Tales immediately. No Warcraft II required.

**README flow B (real WC2, second section):**
1. Own Warcraft II (Battle.net Edition or Remastered).
2. On a desktop, run the extractor against your install to produce `data.Wargus`.
3. AirDrop / Files / USB-C the folder to the iPad.
4. In the app, Import, select the folder. Play real Warcraft II.

**Naming:** ship as "Stratagus RTS" or an original name, not "Warcraft II." The store/repo title and icon are the trademark surface; the engine is not. Describe flow B as "bring your own Warcraft II data."

**What the repo must never contain:** any extracted `data.Wargus`, any Blizzard art/sound/`.mpq`, or any screenshot that is primarily Blizzard art used as your project's branding.

---

## Distribution and signing ladder (tailored)

- **Now, build to your own iPad:** free Apple ID, Xcode, USB deploy. Zero cost. 7-day expiry is irrelevant while you rebuild constantly.
- **Share with enthusiasts:** prebuilt `.ipa` in GitHub Releases + SideStore source. Still free Apple ID; SideStore refreshes on-device over Wi-Fi.
- **Time-boxed viral spike:** TestFlight, up to 10k testers, 90-day builds. Triggers the $99 Developer Program and puts your identity on it. Optional, deliberate.
- **Skip for v1:** AltStore PAL (EU/Japan/Brazil only) and the official App Store (GPLv2 is incompatible with App Store terms; VLC/GNU Go precedent).

The install is never the viral mechanism; sideloading friction guarantees that. The video is the artifact that travels. The repo converts the committed minority.

---

## Codex handoff

You are feeding this to a Codex agent, so set it up to succeed:
- Point Codex at the forked repo and give it `Northfear/stratagus-vita` as the reference ARM/SDL2 port to study. Most iOS answers are one translation away from the Vita solution.
- Drive it phase by phase using the acceptance tests above as the definition of done. Do not let it jump to input work before Phase 2 boots on device.
- Codex is well-suited to the toolchain file, dependency cross-compilation, the sandbox path rework, the SDL2 app wrapper, and the touch/Pencil input layer: bounded C/C++/CMake work with a working reference.
- Codex cannot resolve the GPL/App-Store incompatibility or the trademark exposure. Those are your decisions (de-brand, ship free assets, sideload), already made above.

Suggested first Codex prompt: "Fork Wargus/stratagus and Wargus/wargus. Using Northfear/stratagus-vita as a reference, add a cmake/toolchains/ios-arm64.cmake toolchain and get libstratagus plus the Wargus data layer cross-compiling for iOS arm64 as static libraries. Do not create an app target yet. Report the exact dependency versions and any source changes required."

---

## Legal guardrails (non-negotiable, already decided)

De-brand the app name and icon. Ship only Aleona's Tales; never commit Blizzard data. Users build and sign themselves. Keep the GPLv2 NOTICE. Do not emulate Battle.net (the engine's own LAN/custom netcode is fine, and multiplayer is off for v1 anyway). This is the same posture Stratagus itself used to survive Blizzard's 2003 action, and it is the reason WC2 is a safer target than WC3.

---

## Open questions and decisions

- **Apple tier trigger:** confirmed free-to-start. Revisit only when you want TestFlight or to stop re-signing a stable build.
- **Pencil model:** your 2nd-gen Pencil gives hover + double-tap. If you later move to an M4 iPad Pro + Pencil Pro, squeeze/barrel-roll open up. Plan does not depend on it.
- **Extractor reliability:** the built-in Wargus extractor is buggy on macOS. Phase 0 must confirm the extraction path (built-in or the shinra-electric script) before iOS work.
- **Aleona's Tales scope:** confirm how complete its campaign content is before promising a "full free campaign" in the README. Flagged in the feasibility report as medium confidence.
- **Pinch-to-zoom:** deferred. The engine renders at fixed tile scale; real zoom is a renderer change, post-v1.
- **Repo location:** this plan and the feasibility report currently live in the workspace root next to the other game-feasibility files. Say the word and I will promote both into `projects/warcraft2-ipad/` once this becomes an active build.

---

## Today's single next action

Phase 0. On the Mac: build desktop Wargus, extract your Battle.net Edition v2.02 into `data.Wargus`, and confirm both a real WC2 skirmish and an Aleona's Tales match run. That validates the data pipeline and the free-content path for the price of an afternoon, before a single line of iOS code. If Phase 0 fails, the rest of the plan waits.
