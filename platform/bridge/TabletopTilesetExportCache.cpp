// TabletopTilesetExportCache.cpp
//
// See TabletopTilesetExportCache.h.
#include "TabletopTilesetExportCache.h"

TabletopTilesetExportDecision TabletopTilesetExportCache::Attempt(
    std::uintptr_t graphicIdentity,
    const std::string &name,
    int width, int height,
    std::uint64_t currentGameCycle,
    std::uint64_t retryBackoffTicks) noexcept
{
    const bool keyMatches = m_hasKey
        && m_graphicIdentity == graphicIdentity
        && m_name == name
        && m_width == width
        && m_height == height;

    TabletopTilesetExportDecision decision;

    if (keyMatches) {
        if (m_lastSucceeded) {
            decision.action              = TabletopTilesetExportAction::UseCached;
            decision.cachedRelativePath  = m_relativePath;
            decision.cachedWidth         = m_cachedWidth;
            decision.cachedHeight        = m_cachedHeight;
            return decision;
        }
        if (currentGameCycle < m_lastFailedAtGameCycle + retryBackoffTicks) {
            decision.action = TabletopTilesetExportAction::Backoff;
            return decision;
        }
        // Backoff window elapsed: retry at the *same* version, since the
        // identity (and therefore the target filename) hasn't changed.
        decision.action  = TabletopTilesetExportAction::Export;
        decision.version = m_version;
        return decision;
    }

    // New/changed identity: bump the version so a real content change never
    // reuses a stale filename, even if a later identity coincidentally
    // shares the same (name, width, height) as an earlier one.
    ++m_version;
    m_hasKey          = true;
    m_graphicIdentity = graphicIdentity;
    m_name            = name;
    m_width           = width;
    m_height          = height;
    m_lastSucceeded   = false; // pending until RecordSuccess/RecordFailure

    decision.action  = TabletopTilesetExportAction::Export;
    decision.version = m_version;
    return decision;
}

void TabletopTilesetExportCache::RecordSuccess(
    const std::string &relativePath, std::uint16_t width, std::uint16_t height) noexcept
{
    m_lastSucceeded = true;
    m_relativePath  = relativePath;
    m_cachedWidth   = width;
    m_cachedHeight  = height;
}

void TabletopTilesetExportCache::RecordFailure(std::uint64_t currentGameCycle) noexcept
{
    m_lastSucceeded          = false;
    m_lastFailedAtGameCycle  = currentGameCycle;
}
