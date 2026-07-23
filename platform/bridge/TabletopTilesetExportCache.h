// TabletopTilesetExportCache.h
//
// Pure, framework-free decision logic for the visionOS tabletop's
// expanded-tileset PNG export cache (see PeonPadTabletopBridge.cpp's
// ExportExpandedTilesetPNG). No SDL, Stratagus engine, or filesystem
// dependency — the reload/versioning/backoff *decisions* are unit-tested on
// the host (tests/tabletop_bridge_test.cpp) independent of the actual
// surface write (TabletopTilesetExport.h) or the real CGraphic identity.
//
// Why this exists: Map.TileGraphic is a std::shared_ptr<CGraphic> looked up
// in a filename-keyed, process-lifetime cache (CGraphic::New's GraphicHash —
// see engine/stratagus/src/video/graphic.cpp), so loading the *same*
// tileset file again for a *different* map returns the *same* CGraphic
// pointer, and CGraphic::Load() is then a no-op. GenerateExtendedTileset()
// still runs again on every tileset load, though, appending another copy of
// the generated frames (CGraphic::AppendFrames/ExpandFor always grows the
// surface when it has frames to add) — so a same-pointer, same-name reload
// can still carry a taller (changed) surface. This cache therefore keys on
// (graphic identity, tileset name, surface width, surface height), not
// identity + name alone, and bumps a version counter on any change so a
// Swift-side cache keyed on the exported relative path can never confuse
// two different generations of "the same" tileset.
#pragma once

#include <cstdint>
#include <string>

// What the caller should do for the current snapshot-publish tick, given the
// tileset identity observed and this cache's prior state.
enum class TabletopTilesetExportAction {
    /// Identity unchanged and the last export at this identity succeeded:
    /// reuse `cachedRelativePath`/`cachedWidth`/`cachedHeight`, no I/O.
    UseCached,
    /// Identity changed (or this is the first observation): the caller
    /// should attempt a fresh export using `version`.
    Export,
    /// Identity unchanged, but the last attempt at this identity failed and
    /// not enough game cycles have passed since that failure to retry yet:
    /// do nothing this tick (avoids retrying a broken write path — e.g. an
    /// unwritable cache directory — on every single simulation tick).
    Backoff,
};

struct TabletopTilesetExportDecision {
    TabletopTilesetExportAction action = TabletopTilesetExportAction::Export;
    /// Valid when action == Export: pass to TabletopExportTilesetSurfacePNG
    /// (and therefore TabletopTilesetExportRelativePath).
    unsigned long version = 0;
    /// Valid when action == UseCached.
    std::string   cachedRelativePath;
    std::uint16_t cachedWidth  = 0;
    std::uint16_t cachedHeight = 0;
};

// Tracks whether a (graphicIdentity, name, width, height) tuple has changed
// since the last call, and whether a fresh export is due, already cached, or
// should be skipped due to failure backoff.
//
// `graphicIdentity` is any value stable for the lifetime of one loaded
// CGraphic (the real caller passes its CGraphic pointer, reinterpreted as an
// integer); this class only ever compares it for equality, so tests can use
// arbitrary integers in place of real pointers.
class TabletopTilesetExportCache {
public:
    TabletopTilesetExportDecision Attempt(
        std::uintptr_t graphicIdentity,
        const std::string &name,
        int width, int height,
        std::uint64_t currentGameCycle,
        std::uint64_t retryBackoffTicks) noexcept;

    /// Call after a successful export at the version returned by the most
    /// recent Attempt() (only meaningful when that call returned Export).
    void RecordSuccess(const std::string &relativePath,
                        std::uint16_t width, std::uint16_t height) noexcept;

    /// Call after a failed export attempt at the version returned by the
    /// most recent Attempt() (only meaningful when that call returned
    /// Export).
    void RecordFailure(std::uint64_t currentGameCycle) noexcept;

private:
    bool           m_hasKey = false;
    std::uintptr_t m_graphicIdentity = 0;
    std::string    m_name;
    int            m_width  = -1;
    int            m_height = -1;

    bool           m_lastSucceeded = false;
    std::string    m_relativePath;
    std::uint16_t  m_cachedWidth  = 0;
    std::uint16_t  m_cachedHeight = 0;
    unsigned long  m_version = 0;
    std::uint64_t  m_lastFailedAtGameCycle = 0;
};
