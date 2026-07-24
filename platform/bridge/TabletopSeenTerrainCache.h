// TabletopSeenTerrainCache.h
//
// Pure, engine-independent last-seen terrain metadata cache for the visionOS
// tabletop bridge. The engine stores only SeenTile (graphic frame), so the
// bridge retains the matching logical tile index and terrain class within one
// explicit map/tileset/player epoch.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

struct TabletopSeenTerrainEpoch {
    std::uint64_t loadGeneration = 0;
    std::uint32_t mapUid = 0;
    std::string mapPath;
    std::uintptr_t mapFieldIdentity = 0;
    std::uintptr_t tilesetGraphicIdentity = 0;
    std::string tilesetName;
    std::string tilesetImagePath;
    int tilesetImageWidth = 0;
    int tilesetImageHeight = 0;
    std::size_t tilesetTileCount = 0;
    std::uintptr_t playerIdentity = 0;
    int playerIndex = -1;

    bool operator==(const TabletopSeenTerrainEpoch &other) const noexcept
    {
        return loadGeneration == other.loadGeneration
            && mapUid == other.mapUid
            && mapPath == other.mapPath
            && mapFieldIdentity == other.mapFieldIdentity
            && tilesetGraphicIdentity == other.tilesetGraphicIdentity
            && tilesetName == other.tilesetName
            && tilesetImagePath == other.tilesetImagePath
            && tilesetImageWidth == other.tilesetImageWidth
            && tilesetImageHeight == other.tilesetImageHeight
            && tilesetTileCount == other.tilesetTileCount
            && playerIdentity == other.playerIdentity
            && playerIndex == other.playerIndex;
    }
};

struct TabletopSeenTerrainMetadata {
    std::uint16_t tileIndex = 0;
    std::uint16_t graphicIndex = 0;
    std::uint8_t terrainClass = 0;
    bool valid = false;
};

class TabletopSeenTerrainCache {
public:
    TabletopSeenTerrainCache(
        std::uint16_t neutralTileIndex,
        std::uint8_t neutralTerrainClass) noexcept
        : m_neutralTileIndex(neutralTileIndex)
        , m_neutralTerrainClass(neutralTerrainClass)
    {
    }

    /// Starts or continues one visibility epoch. Returns true when prior
    /// metadata was invalidated due to map, tileset, player, cell-count, or
    /// game-cycle epoch change.
    bool BeginEpoch(
        TabletopSeenTerrainEpoch epoch,
        std::size_t cellCount,
        std::uint64_t gameCycle)
    {
        const bool cycleReset = m_hasEpoch && gameCycle < m_lastGameCycle;
        const bool changed = !m_hasEpoch || cycleReset
            || !(m_epoch == epoch) || m_entries.size() != cellCount;
        m_lastGameCycle = gameCycle;
        if (!changed) {
            return false;
        }
        m_hasEpoch = true;
        m_epoch = std::move(epoch);
        m_entries.assign(cellCount, NeutralUnseen());
        return true;
    }

    void Reset() noexcept
    {
        m_hasEpoch = false;
        m_lastGameCycle = 0;
        m_epoch = {};
        m_entries.clear();
    }

    void RecordVisible(
        std::size_t index,
        std::uint16_t graphicIndex,
        std::uint16_t tileIndex,
        std::uint8_t terrainClass) noexcept
    {
        if (index >= m_entries.size()) {
            return;
        }
        m_entries[index] = {
            tileIndex, graphicIndex, terrainClass, true
        };
    }

    template <typename Resolver>
    TabletopSeenTerrainMetadata ResolveExplored(
        std::size_t index,
        std::uint16_t graphicIndex,
        Resolver &&resolver)
    {
        if (index >= m_entries.size()) {
            return NeutralExplored(graphicIndex);
        }
        auto &entry = m_entries[index];
        if (!entry.valid || entry.graphicIndex != graphicIndex) {
            std::uint16_t tileIndex = m_neutralTileIndex;
            std::uint8_t terrainClass = m_neutralTerrainClass;
            if (resolver(graphicIndex, tileIndex, terrainClass)) {
                entry = {tileIndex, graphicIndex, terrainClass, true};
            } else {
                entry = NeutralExplored(graphicIndex);
            }
        }
        return entry;
    }

    TabletopSeenTerrainMetadata NeutralUnseen() const noexcept
    {
        return {
            m_neutralTileIndex, 0u, m_neutralTerrainClass, false
        };
    }

private:
    TabletopSeenTerrainMetadata NeutralExplored(
        std::uint16_t graphicIndex) const noexcept
    {
        return {
            m_neutralTileIndex, graphicIndex, m_neutralTerrainClass, false
        };
    }

    std::uint16_t m_neutralTileIndex;
    std::uint8_t m_neutralTerrainClass;
    bool m_hasEpoch = false;
    std::uint64_t m_lastGameCycle = 0;
    TabletopSeenTerrainEpoch m_epoch;
    std::vector<TabletopSeenTerrainMetadata> m_entries;
};
