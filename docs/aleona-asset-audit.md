# Aleona's Tales asset audit

## Result

The locked Aleona/Timeless Tales snapshot at commit
`695d3ed6464cfa186c42e4804ee1e2c4e88f6e09` is suitable for private local
testing but is **not approved for distribution**.

The repository root has never contained a blanket license grant. Inspection
of its complete local Git history shows that every historical root README only
identifies the project as “Timeless Tales.” An author name or copyright notice
does not itself grant redistribution rights.

Run the deterministic audit with:

```sh
./scripts/audit-aleona-assets.sh --strict
```

The strict command intentionally fails at this revision. Private development
builds use:

```sh
./scripts/audit-aleona-assets.sh --local-test
```

## Current inventory

The audit inspects raster graphics, audio, music, source-image formats, and the
soundfont contained in the staged snapshot:

| Classification | Files |
| --- | ---: |
| Media inspected | 2,849 |
| Covered by the vendored Wyrmsun GPL/CC declaration | 2,037 |
| Non-vendor media with an explicit adjacent grant | 15 |
| Adjacent author attribution but no license grant | 112 |
| No adjacent provenance record | 685 |
| Vendored Steam-only exceptions present | 0 |
| Missing files from Wyrmsun's CC-BY-SA declaration | 0 |
| **Unresolved** | **797** |

The Wyrmsun subtree cannot replace Aleona as the playable payload. A direct
stock-Stratagus boot was tested from an isolated runtime copy: after removing
its forbidden Steam Workshop lookup, it stopped on the Wyrmgus-specific
`silver` resource. Substituting it would therefore break the promised Aleona
vertical slice.

## Release gate

The current iOS application is a local device-testing artifact. Any future
distribution workflow must run the strict audit and must not override its
failure. To clear the gate, the project needs one of:

1. A blanket license grant from the relevant Aleona copyright holders that
   covers the snapshot and its maps, graphics, sound, and music.
2. Explicit licenses and required attribution for every unresolved file.
3. A replacement, stock-Stratagus-compatible content set whose complete asset
   provenance is already verified.

Scripts and map sources require a separate corresponding-source and notice
review before a release is approved; the media failures already make the
current result non-distributable.
