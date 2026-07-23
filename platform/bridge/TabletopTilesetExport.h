// TabletopTilesetExport.h
//
// SDL3-only (no Stratagus engine dependency) tileset PNG export core for the
// visionOS live tabletop. See PeonPadTabletopBridge.cpp's
// ExportExpandedTilesetPNG for why this exists and how it is used from the
// real engine, and TabletopTilesetPath.h for the pure path-naming logic this
// builds on.
//
// Kept free of any Stratagus/CTileset/Map dependency so it can be linked and
// exercised end-to-end (real IMG_SavePNG write + decode) by a small,
// SDL3-only regression test (tests/tabletop_tileset_export_test.cpp) without
// dragging in the whole engine.
#pragma once

#include <SDL3/SDL.h>

#include <cstdint>
#include <string>

// Result of a tileset PNG export attempt.
struct TabletopTilesetExportResult {
    bool ok = false;
    /// Relative to `cacheRootDir`, forward-slash separated, e.g.
    /// "tabletop-generated/forest-v1-3f9a1c2b4d5e6f70.png". Empty when
    /// `ok == false`.
    std::string relativePath;
    std::uint16_t width  = 0;
    std::uint16_t height = 0;
};

// Exports `surface` as a PNG under `cacheRootDir`, at the path computed by
// TabletopTilesetExportRelativePath(tilesetName, tilesetSourcePath, version).
//
// Writes atomically: encodes to a uniquely-named temporary file in the same
// directory, then renames it over the destination. A concurrent reader can
// therefore only ever see the previous complete file (if any) or the new
// complete file — never a partially-written one. Every (tilesetName,
// tilesetSourcePath, version) triple maps to its own filename, so a caller
// that bumps `version` on every real content change never overwrites a
// filename another (possibly still-cached) snapshot descriptor references.
//
// Returns `ok == false` (never throws, never crashes) on any failure: a
// null/degenerate/oversized surface, a directory that cannot be created, or
// an IMG_SavePNG failure (e.g. permission denied, disk full). The caller is
// expected to fall back to other content and/or back off retrying every
// tick — this function itself performs no retry or backoff bookkeeping.
TabletopTilesetExportResult TabletopExportTilesetSurfacePNG(
    SDL_Surface *surface,
    const std::string &tilesetName,
    const std::string &tilesetSourcePath,
    unsigned long version,
    const std::string &cacheRootDir) noexcept;
