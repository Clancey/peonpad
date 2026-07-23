// TabletopTilesetPath.h
//
// Pure, framework-free naming logic for the visionOS tabletop's exported
// tileset PNG cache (see TabletopTilesetExport.h for the actual PNG write,
// and PeonPadTabletopBridge.cpp's ExportExpandedTilesetPNG for why this
// export exists: Wargus tilesets procedurally generate additional tile
// frames at load time — GenerateExtendedTileset() — that are appended only
// to the engine's in-memory tile graphic, never to the on-disk tileset PNG).
//
// Nothing here depends on SDL, Stratagus engine globals, or the filesystem —
// it is pure string/hash math, so it compiles and is unit-tested in the
// standalone host build (tests/tabletop_bridge_test.cpp) with zero extra
// link dependencies, in addition to the real engine and the SDL3-linked
// exporter test (tests/tabletop_tileset_export_test.cpp).
#pragma once

#include <string>

// Keeps a tileset's display name safe for use as a single path segment: only
// lowercase alphanumerics, '-', and '_' survive; everything else is dropped.
// Falls back to "tileset" for a name that sanitizes to nothing (e.g. empty,
// or entirely punctuation/whitespace). This is a *display* aid only — two
// different tilesets can sanitize to the same string (e.g. "Ice Cliffs-2"
// and "IceCliffs-2" both sanitize to "icecliffs-2"); collision resistance
// comes from the hash in TabletopTilesetExportRelativePath, which is
// computed over the full, unsanitized identity.
std::string TabletopSanitizeTilesetCacheName(const std::string &tilesetName) noexcept;

// The staged-cache-root-relative path where the exported/expanded tileset
// PNG identified by (tilesetName, tilesetSourcePath, version) is (or will
// be) written. Always under a single fixed subdirectory
// ("tabletop-generated/") so it never collides with authored asset paths.
//
// `version` disambiguates repeated exports of a *changed* tileset within one
// process lifetime (the same CGraphic instance and tileset name can outlive
// a map reload — see the cache-key comment in
// PeonPadTabletopBridge.cpp's ExportExpandedTilesetPNG — so pointer+name
// alone is not sufficient to detect that the underlying pixel content
// changed). Bumping `version` on any real content change yields a brand new
// filename, so Swift-side per-path caches (keyed on relativePath) can never
// serve stale pixels for new content.
//
// The result is guaranteed to be well under PEONPAD_TABLETOP_MAX_PATH
// (128 bytes including the NUL terminator, see PeonPadTabletopBridge.h) by
// construction: a fixed-width 16-hex-digit content hash plus an at-most
// 20-character sanitized display prefix, with a defensive fallback that
// drops the display prefix entirely should the computed path ever approach
// the budget. The hash is computed over the *unsanitized* tilesetName,
// tilesetSourcePath, and version together, so two distinct tilesets that
// happen to sanitize to the same display prefix (or the same tileset
// reloaded at a different version) never collide on the same path.
std::string TabletopTilesetExportRelativePath(
    const std::string &tilesetName,
    const std::string &tilesetSourcePath,
    unsigned long version) noexcept;
