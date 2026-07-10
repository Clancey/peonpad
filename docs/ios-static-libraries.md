# PeonPad iOS arm64 static-library baseline

Phase 1 cross-compiles the engine and its Wargus data bridge for a physical
iOS/iPadOS arm64 device. It deliberately does not create, sign, or launch an
app; that is the next phase.

## Build

The macOS baseline must be built first because the cross-build uses its native
`tolua++` generator. Then run:

```sh
./scripts/build-macos.sh
./scripts/build-ios-libs.sh
```

The iOS build uses only revision-locked staged sources and the selected Xcode
iPhoneOS SDK. It downloads nothing and checks the complete `ref/` digest before
and after.

Outputs:

```text
build/ios-arm64/engine/libstratagus_lib.a
build/ios-arm64/wargus/libwargus_data.a
```

Both archives contain only arm64 Mach-O objects with `LC_BUILD_VERSION`
platform 2 (iOS), minimum iOS 16.0, and SDK 26.5 on the captured toolchain.

## Compatibility changes

- Nested dependency builds inherit the iPhoneOS SDK, arm64 architecture, and
  deployment target.
- Dependency feature probes compile static libraries rather than trying to
  execute target code on the Mac.
- Vendored Lua builds only its static runtime and tolua library. `os.execute`
  is disabled because Apple marks `system(3)` unavailable on iOS.
- bzip2 and libpng no longer require installing desktop command-line bundles
  during an iOS static-library build.
- `strcpy_s`/`strncpy_s` probe false positives are disabled so Stratagus uses
  its portable compatibility implementations.
- Wargus exposes a small static data bridge for the later app target; its
  desktop extractor/launcher is intentionally excluded from iOS.

## Acceptance evidence

Captured July 10, 2026:

- `libstratagus_lib.a`: arm64, 184 iOS object files.
- `libwargus_data.a`: arm64, one iOS object file.
- SDL configured its UIKit video, CoreAudio, Metal renderer, touch/event, and
  iOS filesystem backends.
- The complete Stratagus engine and UI sources compiled successfully.
- The locked `ref/` tree remained byte-for-byte unchanged.

Phase 1 is accepted when `./scripts/build-ios-libs.sh` prints success. Phase 2
will add the minimal Xcode/SDL app shell and container-safe runtime paths.
