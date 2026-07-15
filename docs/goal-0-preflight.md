# Goal 0 preflight status

Captured July 10, 2026 on the PeonPad development Mac.

## Outcome

Goal 0 is accepted. All required source repositories, submodules, dependency
snapshots, reference content, and Apple toolchains are locked and verified.
Both the native macOS and iPhoneOS arm64 compiler probes pass.

The authoritative machine-readable record is `config/inputs.lock`. The public
and maintainer contracts are now separate: a clone verifies the tracked source
snapshots and Apple toolchain, while maintainers can additionally verify the
private evidence fixture.

## Passing evidence

- `ref/` is ignored and contains no tracked files.
- Its 21,257 substantive files total 2,220,448,058 bytes. Git internals and
  `.DS_Store` files are deliberately excluded from this content identity.
- Its deterministic content digest is
  `c1782ea011559049ce65b739c6cbe5825a4db3b1c8d2afaea0dbcb54e7357f8f`.
- The digest was identical before and after preflight.
- Stratagus is locked to `3d87c93f7fd8c0b62ee1be5df0a6d9efc72ca6cc`.
- Wargus is locked to `cde1a0718a0058cc651ecd56ff8149fc39f624e9`.
- Stratagus Vita is locked to `5454452ec3ef9f6a14e51a57be8fe13e44893cdf`.
- Aleona's Tales is locked to
  `695d3ed6464cfa186c42e4804ee1e2c4e88f6e09`.
- All four reference repositories and required submodules are clean.
- CMake 3.27.1 and Apple clang 21.0.0 compile the root C++ probe as an arm64
  macOS static library.
- Xcode 26.6 is selected at `/Applications/Xcode.app/Contents/Developer`.
- The iPhoneOS 26.5 SDK compiles an arm64 object whose `LC_BUILD_VERSION`
  platform is iOS.
- Automated script guardrails reject binaries under `ref/`, route `-d` and
  `-u` separately, isolate HOME/cache/temp state, and preserve the reference
  digest around a fake-engine run.
- The reference executable's help output confirms `-d datapath` and
  `-u userpath` as the supported data and writable-state controls.
- Proprietary data, installers, MPQs, build output, runtime state, caches,
  saves, and signing material are covered by repository ignore rules.

## License gate carried forward

The engine and Wargus code are GPLv2. The Aleona/Timeless Tales repository has
many per-asset attribution files and GPL-covered vendor material, but no single
root license covering every asset. Its manifest status is therefore
`REVIEW_REQUIRED_BEFORE_BUNDLING`. Local baseline testing is allowed; the
asset set must not be represented as fully cleared or shipped in an app until
that audit is completed.

## Reproduction

```sh
./scripts/preflight.sh
./tests/script-guardrails.sh
file build/preflight-macos/libpeonpad_toolchain_probe.a
lipo -info build/preflight-macos/libpeonpad_toolchain_probe.a
```

The public commands download nothing and do not require `ref/`. They verify the
tracked Stratagus and Wargus revision markers, proprietary-data ignore rules,
host tools, and macOS/iOS ARM64 compiler probes.

Maintainers can reproduce the original immutable-input evidence with:

```sh
./scripts/reference-digest.sh
./scripts/preflight.sh --maintainer
./tests/script-guardrails.sh --maintainer
```

Maintainer mode never writes into `ref/`; revision, worktree, or content drift
turns that optional gate red without blocking a public user build.
