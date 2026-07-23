// PeonPadTabletopBridge.cpp
//
// Engine-side implementation of the visionOS live tabletop bridge.
//
// When compiled with PEONPAD_TABLETOP defined (the engine build) this file
// reads from Stratagus global state (UnitManager, Map, ThisPlayer, FogOfWar,
// GameCycle, Selected, …) and exposes it through the C ABI declared in
// PeonPadTabletopBridge.h.
//
// Without PEONPAD_TABLETOP (the standalone test build) the engine-specific
// peonpad_tabletop_publish_snapshot() and peonpad_tabletop_drain_commands()
// are no-ops.  All infrastructure (snapshot lifecycle, command queue,
// peonpad_tabletop_publish_synthetic) is always compiled and testable.

#include "PeonPadTabletopBridge.h"
#include "TabletopTilesetPath.h"

#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

// ── Engine state includes (simulation thread only) ───────────────────────

#ifdef PEONPAD_TABLETOP
#include "TabletopTilesetExport.h"
#include "TabletopTilesetExportCache.h"
#include "commands.h"
#include "fow.h"
#include "interface.h"
#include "iolib.h"
#include "map.h"
#include "parameters.h"
#include "player.h"
#include "stratagus.h"
#include "tile.h"
#include "tileset.h"
#include "unit.h"
#include "unit_manager.h"
#include "unittype.h"
#include "vec2i.h"
#include "video.h"
#endif

// ── Internal snapshot struct ──────────────────────────────────────────────

struct PeonPadSnapshot {
    std::atomic<int>                refcount{1};
    uint64_t                        generation  = 0;
    uint32_t                        map_width   = 0;
    uint32_t                        map_height  = 0;
    std::vector<PeonPadTerrainCell> terrain;    // map_width * map_height cells
    std::vector<PeonPadUnitRecord>  units;
    std::vector<PeonPadUnitType>    unit_types; // ABI v2: type_id → ident registry
    bool                            has_tileset = false; // ABI v3
    PeonPadTilesetDescriptor        tileset{};  // ABI v3: active-map tileset
};

// ── Bridge state (owned by simulation thread) ─────────────────────────────

namespace {

struct TabletopBridgeState {
    // cmd_mutex protects initialized, pending, and lifecycle transitions.
    // Holding cmd_mutex when reading/writing initialized prevents the
    // check-then-enqueue race between post_command() and cleanup().
    std::mutex                  cmd_mutex;
    bool                        initialized = false;  // guarded by cmd_mutex

    // Snapshot double-buffer: snap_mutex is independent of cmd_mutex.
    std::mutex                  snap_mutex;
    PeonPadSnapshot            *latest      = nullptr;  // guarded by snap_mutex

    std::vector<PeonPadCommand> pending;                // guarded by cmd_mutex
};

TabletopBridgeState g_bridge;

// Release a snapshot (NULL-safe).
void SnapRelease(PeonPadSnapshot *s) noexcept
{
    if (!s) return;
    if (s->refcount.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        delete s;
    }
}

// Publish a fully-constructed snapshot as the new latest.
// Takes ownership of |snap| (caller must not use it afterwards).
// Drops the previous latest snapshot's bridge reference.
void PublishSnap(PeonPadSnapshot *snap) noexcept
{
    PeonPadSnapshot *old = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_bridge.snap_mutex);
        old = g_bridge.latest;
        g_bridge.latest = snap;
    }
    SnapRelease(old);
}

// Validate a command posted by the UI thread.
bool CommandIsValid(const PeonPadCommand *cmd) noexcept
{
    if (!cmd) return false;
    if (cmd->abi_ver != PEONPAD_TABLETOP_ABI_VERSION) return false;
    switch (static_cast<PeonPadCommandType>(cmd->type)) {
        case PEONPAD_CMD_SELECT:
        case PEONPAD_CMD_DESELECT:
        case PEONPAD_CMD_STOP:
        case PEONPAD_CMD_DESELECT_ALL:
            return true;
        case PEONPAD_CMD_MOVE:
            // Reject tiles beyond the hard map limit.
            return (cmd->tile_x >= 0 && cmd->tile_y >= 0
                    && static_cast<uint32_t>(cmd->tile_x) < PEONPAD_TABLETOP_MAX_MAP_DIM
                    && static_cast<uint32_t>(cmd->tile_y) < PEONPAD_TABLETOP_MAX_MAP_DIM);
        default:
            return false;
    }
}

} // namespace

// ── Public C API: snapshot accessors ─────────────────────────────────────

extern "C" {

uint32_t peonpad_snapshot_abi_version(const PeonPadSnapshot *s)
{
    if (!s) return 0;
    return PEONPAD_TABLETOP_ABI_VERSION;
}

uint64_t peonpad_snapshot_generation(const PeonPadSnapshot *s)
{
    return s ? s->generation : 0u;
}

uint32_t peonpad_snapshot_map_width(const PeonPadSnapshot *s)
{
    return s ? s->map_width : 0u;
}

uint32_t peonpad_snapshot_map_height(const PeonPadSnapshot *s)
{
    return s ? s->map_height : 0u;
}

uint32_t peonpad_snapshot_terrain_count(const PeonPadSnapshot *s)
{
    return s ? static_cast<uint32_t>(s->terrain.size()) : 0u;
}

const PeonPadTerrainCell *peonpad_snapshot_terrain(const PeonPadSnapshot *s)
{
    if (!s || s->terrain.empty()) return nullptr;
    return s->terrain.data();
}

uint32_t peonpad_snapshot_unit_count(const PeonPadSnapshot *s)
{
    return s ? static_cast<uint32_t>(s->units.size()) : 0u;
}

const PeonPadUnitRecord *peonpad_snapshot_units(const PeonPadSnapshot *s)
{
    if (!s || s->units.empty()) return nullptr;
    return s->units.data();
}

uint32_t peonpad_snapshot_unit_type_count(const PeonPadSnapshot *s)
{
    return s ? static_cast<uint32_t>(s->unit_types.size()) : 0u;
}

const PeonPadUnitType *peonpad_snapshot_unit_types(const PeonPadSnapshot *s)
{
    if (!s || s->unit_types.empty()) return nullptr;
    return s->unit_types.data();
}

const PeonPadTilesetDescriptor *peonpad_snapshot_tileset(const PeonPadSnapshot *s)
{
    if (!s || !s->has_tileset) return nullptr;
    return &s->tileset;
}

int peonpad_snapshot_retain(PeonPadSnapshot *s)
{
    if (!s) return -1;
    s->refcount.fetch_add(1, std::memory_order_relaxed);
    return 0;
}

void peonpad_snapshot_release(PeonPadSnapshot *s)
{
    SnapRelease(s);
}

// ── Bridge lifecycle ───────────────────────────────────────────────────────

int peonpad_tabletop_init(void)
{
    std::lock_guard<std::mutex> lk(g_bridge.cmd_mutex);
    if (g_bridge.initialized) return -1;
    g_bridge.initialized = true;
    return 0;
}

void peonpad_tabletop_cleanup(void)
{
    // Clear the command queue and mark uninitialized atomically under cmd_mutex
    // so no in-flight post_command can enqueue after cleanup returns.
    std::vector<PeonPadCommand> old_cmds;
    {
        std::lock_guard<std::mutex> lk(g_bridge.cmd_mutex);
        old_cmds.swap(g_bridge.pending);
        g_bridge.initialized = false;
    }
    // Drop the latest snapshot.
    PeonPadSnapshot *old = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_bridge.snap_mutex);
        old = g_bridge.latest;
        g_bridge.latest = nullptr;
    }
    SnapRelease(old);
}

// ── Command intake ─────────────────────────────────────────────────────────

int peonpad_tabletop_post_command(const PeonPadCommand *cmd)
{
    if (!CommandIsValid(cmd)) return -2;
    std::lock_guard<std::mutex> lk(g_bridge.cmd_mutex);
    // Check initialized under the same lock that cleanup() holds when it
    // clears initialized — prevents enqueueing after cleanup returns.
    if (!g_bridge.initialized) return -1;
    if (g_bridge.pending.size() >= PEONPAD_TABLETOP_MAX_COMMANDS) return -3;
    g_bridge.pending.push_back(*cmd);
    return 0;
}

PeonPadSnapshot *peonpad_tabletop_latest_snapshot(void)
{
    // No initialized check needed: when the bridge is uninitialized the
    // snapshot pointer is null (set to null in cleanup), so callers safely
    // receive nullptr.  Snap_mutex provides the required ordering.
    PeonPadSnapshot *s = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_bridge.snap_mutex);
        s = g_bridge.latest;
        if (s) s->refcount.fetch_add(1, std::memory_order_relaxed);
    }
    return s;
}

// ── Synthetic publish (test support) ────────────────────────────────────

int peonpad_tabletop_publish_synthetic(
    uint64_t                    generation,
    uint32_t                    map_width,
    uint32_t                    map_height,
    const PeonPadTerrainCell   *terrain,
    uint32_t                    terrain_count,
    const PeonPadUnitRecord    *units,
    uint32_t                    unit_count)
{
    return peonpad_tabletop_publish_synthetic_v3(
        generation, map_width, map_height,
        terrain, terrain_count, units, unit_count,
        nullptr, 0, nullptr);
}

int peonpad_tabletop_publish_synthetic_v2(
    uint64_t                    generation,
    uint32_t                    map_width,
    uint32_t                    map_height,
    const PeonPadTerrainCell   *terrain,
    uint32_t                    terrain_count,
    const PeonPadUnitRecord    *units,
    uint32_t                    unit_count,
    const PeonPadUnitType      *types,
    uint32_t                    type_count)
{
    return peonpad_tabletop_publish_synthetic_v3(
        generation, map_width, map_height,
        terrain, terrain_count, units, unit_count,
        types, type_count, nullptr);
}

int peonpad_tabletop_publish_synthetic_v3(
    uint64_t                        generation,
    uint32_t                        map_width,
    uint32_t                        map_height,
    const PeonPadTerrainCell       *terrain,
    uint32_t                        terrain_count,
    const PeonPadUnitRecord        *units,
    uint32_t                        unit_count,
    const PeonPadUnitType          *types,
    uint32_t                        type_count,
    const PeonPadTilesetDescriptor *tileset)
{
    {
        std::lock_guard<std::mutex> lk(g_bridge.cmd_mutex);
        if (!g_bridge.initialized) return -1;
    }

    // Validate counts.
    const uint64_t expected_cells =
        static_cast<uint64_t>(map_width) * static_cast<uint64_t>(map_height);
    if (expected_cells > PEONPAD_TABLETOP_MAX_MAP_DIM * PEONPAD_TABLETOP_MAX_MAP_DIM) return -2;
    if (terrain_count != static_cast<uint32_t>(expected_cells)) return -2;
    if (unit_count > PEONPAD_TABLETOP_MAX_UNITS) return -2;
    if (terrain_count > 0 && !terrain) return -2;
    if (unit_count > 0 && !units) return -2;
    if (type_count > PEONPAD_TABLETOP_MAX_UNIT_TYPES) return -2;
    if (type_count > 0 && !types) return -2;

    // Every ident and sprite_path must be NUL-terminated within its buffer.
    for (uint32_t i = 0; i < type_count; ++i) {
        if (memchr(types[i].ident, '\0', PEONPAD_TABLETOP_MAX_IDENT) == nullptr) {
            return -2;
        }
        if (memchr(types[i].sprite_path, '\0', PEONPAD_TABLETOP_MAX_PATH) == nullptr) {
            return -2;
        }
    }

    // The tileset image_path and name must be NUL-terminated when present.
    if (tileset) {
        if (memchr(tileset->image_path, '\0', PEONPAD_TABLETOP_MAX_PATH) == nullptr) {
            return -2;
        }
        if (memchr(tileset->name, '\0', PEONPAD_TABLETOP_MAX_IDENT) == nullptr) {
            return -2;
        }
    }

    auto *snap = new (std::nothrow) PeonPadSnapshot;
    if (!snap) return -1;

    snap->generation = generation;
    snap->map_width  = map_width;
    snap->map_height = map_height;

    if (terrain_count > 0) {
        snap->terrain.assign(terrain, terrain + terrain_count);
    }
    if (unit_count > 0) {
        snap->units.assign(units, units + unit_count);
    }
    if (type_count > 0) {
        snap->unit_types.assign(types, types + type_count);
    }
    if (tileset) {
        snap->has_tileset = true;
        snap->tileset = *tileset;
    }

    // Re-check initialized under cmd_mutex and publish atomically.  Without
    // this second check, a concurrent cleanup() could run between the first
    // check (line ~304) and PublishSnap, setting latest = nullptr and
    // releasing the bridge's reference — leaving the snapshot we're about to
    // publish with a refcount of 1 that is never released (memory leak) and
    // with latest != nullptr while initialized == false (broken invariant).
    {
        std::lock_guard<std::mutex> lk(g_bridge.cmd_mutex);
        if (!g_bridge.initialized) {
            delete snap;
            return -1;
        }
        PublishSnap(snap);
    }
    return 0;
}

// ── Engine capture (simulation thread) ───────────────────────────────────

#ifdef PEONPAD_TABLETOP

// Classify a tile's engine flags into a transport-neutral terrain class.
// The order matters: the most visually-salient/blocking classes win so the
// UI renders forests, rocks and walls distinctly even when a tile also
// carries land/coast flags.
static uint8_t ClassifyTerrain(tile_flags flags) noexcept
{
    if (flags & MapFieldWall)   return static_cast<uint8_t>(PEONPAD_TERRAIN_WALL);
    if (flags & MapFieldForest) return static_cast<uint8_t>(PEONPAD_TERRAIN_FOREST);
    if (flags & MapFieldRocks)  return static_cast<uint8_t>(PEONPAD_TERRAIN_ROCK);
    if (flags & MapFieldWaterAllowed) return static_cast<uint8_t>(PEONPAD_TERRAIN_WATER);
    if (flags & MapFieldCoastAllowed) return static_cast<uint8_t>(PEONPAD_TERRAIN_COAST);
    if (flags & MapFieldLandAllowed)  return static_cast<uint8_t>(PEONPAD_TERRAIN_GRASS);
    return static_cast<uint8_t>(PEONPAD_TERRAIN_DIRT);
}

// Resolve a raw Lua asset path (e.g. "tilesets/summer/terrain/summer.png" or
// "orc/units/grunt.png") to a path that is relative to the staged game-data
// root, as the Swift material provider expects.
//
// Stratagus Lua scripts store unresolved paths without the "graphics/" prefix
// that the engine's LibraryFileName() adds when locating files under the
// staged data directory.  CTileset::ImageFile and CUnitType::File both carry
// these unresolved Lua values.  Calling LibraryFileName() here mirrors the
// same resolution the engine performs when loading the graphic, so the Swift
// layer receives the exact relative path it can open from the data root.
//
// If LibraryFileName returns an absolute path whose prefix is StratagusLibPath,
// the prefix is stripped to produce a root-relative path.  If resolution fails
// (file not found), the original `raw` value is used as a fallback.
static std::string ResolveAssetPath(const std::string &raw) noexcept
{
    if (raw.empty()) return raw;
    try {
        const std::string resolved = LibraryFileName(raw);
        if (resolved.empty()) return raw;
        // Strip the StratagusLibPath prefix when it is present so the result
        // is relative to the staged data root.
        const std::string &base = StratagusLibPath;
        if (!base.empty() && resolved.rfind(base, 0) == 0) {
            std::string rel = resolved.substr(base.size());
            while (!rel.empty() && rel[0] == '/') rel = rel.substr(1);
            return rel.empty() ? raw : rel;
        }
        return resolved;
    } catch (...) {
        return raw;
    }
}

// Exports the engine's actual, fully-expanded tile graphic (base tileset PNG
// frames plus any procedurally-generated extended frames appended by
// GenerateExtendedTileset — see the file-level comment in
// TabletopTilesetPath.h) to a PNG under the writable user/cache directory
// (Parameters::Instance.GetUserDirectory() — the `-u` root; never the
// read-only `-d` staged data root, which EngineStartupPlan.swift documents
// as a directory "the engine never writes into"), once per *distinct*
// tileset load. Returns the cache-root-relative path on success ("" on any
// failure), in which case the caller falls back to the raw authored asset
// (correct only for a tileset with no extended/generated frames referenced
// by the current map).
//
// All reload/versioning/backoff *decision* logic lives in the pure,
// host-testable TabletopTilesetExportCache (see its header for why identity
// must include the surface dimensions, not just the CGraphic pointer +
// tileset name); this function only supplies the engine-specific identity
// (the CGraphic pointer, tileset name/source, and surface) and the actual
// PNG write (TabletopExportTilesetSurfacePNG).
static std::string ExportExpandedTilesetPNG(const CTileset &ts,
                                             uint16_t &out_width,
                                             uint16_t &out_height) noexcept
{
    static TabletopTilesetExportCache s_cache;
    constexpr uint64_t kRetryBackoffTicks = 300; // ~a few seconds of sim time

    if (!Map.TileGraphic) return {};
    CGraphic *graphic = Map.TileGraphic.get();
    SDL_Surface *surface = graphic->getSurface();
    if (!surface || surface->w <= 0 || surface->h <= 0) return {};
    if (surface->w > UINT16_MAX || surface->h > UINT16_MAX) return {};

    const TabletopTilesetExportDecision decision = s_cache.Attempt(
        reinterpret_cast<std::uintptr_t>(graphic), ts.Name,
        surface->w, surface->h,
        static_cast<uint64_t>(GameCycle), kRetryBackoffTicks);

    if (decision.action == TabletopTilesetExportAction::UseCached) {
        out_width  = decision.cachedWidth;
        out_height = decision.cachedHeight;
        return decision.cachedRelativePath;
    }
    if (decision.action == TabletopTilesetExportAction::Backoff) {
        return {};
    }

    const std::string cacheRoot = Parameters::Instance.GetUserDirectory().string();
    const TabletopTilesetExportResult exported = TabletopExportTilesetSurfacePNG(
        surface, ts.Name, ts.ImageFile, decision.version, cacheRoot);

    if (!exported.ok) {
        s_cache.RecordFailure(static_cast<uint64_t>(GameCycle));
        return {};
    }

    s_cache.RecordSuccess(exported.relativePath, exported.width, exported.height);
    out_width  = exported.width;
    out_height = exported.height;
    return exported.relativePath;
}

// Replicate the engine's DrawUnitType() frame resolution (see
// engine/stratagus/src/unit/unittype.cpp) so the UI receives the exact
// sprite-sheet frame index and horizontal-mirror flag the engine itself would
// draw for the unit's current facing + animation.  Keeping this one formula in
// engine-owned C++ (rather than re-deriving it in Swift) is what lets the UI
// stay a pure consumer of stable asset identifiers.
static void ResolveSpriteFrame(const CUnitType &type, int frame,
                               uint16_t &out_frame, uint8_t &out_mirror) noexcept
{
    if (type.Flip) {
        // Five directions stored; the mirrored half uses a negative frame that
        // draws frame (-frame - 1) horizontally flipped.
        if (frame < 0) {
            out_frame  = static_cast<uint16_t>(-frame - 1);
            out_mirror = 1u;
        } else {
            out_frame  = static_cast<uint16_t>(frame);
            out_mirror = 0u;
        }
        return;
    }

    // All directions stored (no mirroring): fold the direction into the frame.
    const int dirs = type.NumDirections;
    if (dirs <= 0) {
        out_frame  = static_cast<uint16_t>(frame < 0 ? -frame - 1 : frame);
        out_mirror = 0u;
        return;
    }
    const int row = dirs / 2 + 1;
    int resolved;
    if (frame < 0) {
        resolved = ((-frame - 1) / row) * dirs + dirs - (-frame - 1) % row;
    } else {
        resolved = (frame / row) * dirs + frame % row;
    }
    out_frame  = static_cast<uint16_t>(resolved < 0 ? 0 : resolved);
    out_mirror = 0u;
}

// Drain queued commands and apply them to the running game state.
// Called from the simulation thread before GameLogicLoop().
void peonpad_tabletop_drain_commands(void)
{
    if (!g_bridge.initialized) return;
    if (!ThisPlayer) return;

    // The visionOS tabletop drives the engine headlessly with no in-engine
    // pause UI. Some scenarios start paused (briefing/objectives) waiting for a
    // key the headless host never sends, which would freeze GameCycle at 0.
    // Keep the simulation advancing so snapshots reflect live gameplay and
    // command round-trips are visible; also clear any cycle-skip left by
    // replay/fast-forward. This only affects the tabletop bridge build.
    if (GamePaused) GamePaused = false;
    if (SkipGameCycle >= 1) SkipGameCycle = 0;

    std::vector<PeonPadCommand> batch;
    {
        std::lock_guard<std::mutex> lk(g_bridge.cmd_mutex);
        batch.swap(g_bridge.pending);
    }
    if (batch.empty()) return;

    for (const PeonPadCommand &cmd : batch) {
        if (cmd.type == PEONPAD_CMD_SELECT || cmd.type == PEONPAD_CMD_DESELECT) {
            CUnit *target = nullptr;
            const unsigned slot_count = UnitManager->GetUsedSlotCount();
            for (unsigned i = 0; i < slot_count; ++i) {
                CUnit &u = UnitManager->GetSlotUnit(static_cast<int>(i));
                if (u.IsAliveOnMap()
                    && static_cast<uint32_t>(UnitNumber(u)) == cmd.unit_id) {
                    target = &u;
                    break;
                }
            }
            if (target) {
                if (cmd.type == PEONPAD_CMD_SELECT) {
                    SelectUnit(*target);
                    SelectedUnitChanged();
                } else {
                    UnSelectUnit(*target);
                    SelectedUnitChanged();
                }
            }
        } else if (cmd.type == PEONPAD_CMD_MOVE) {
            // Issue move orders.  Vec2i stores short components; map tiles are
            // bounded well within a short (≤ PEONPAD_TABLETOP_MAX_MAP_DIM).
            const Vec2i dest{static_cast<short>(cmd.tile_x),
                             static_cast<short>(cmd.tile_y)};
            // Reject coordinates outside the loaded map — static
            // PEONPAD_TABLETOP_MAX_MAP_DIM only catches the absolute
            // maximum; real maps are much smaller.
            if (!Map.Info.IsPointOnMap(dest)) continue;

            if (cmd.unit_id != 0) {
                // unit_id != 0: select just that unit, then move it.
                // Matches Swift TabletopTransport.send(.moveUnit(id, dest)).
                CUnit *target = nullptr;
                const unsigned slot_count = UnitManager->GetUsedSlotCount();
                for (unsigned i = 0; i < slot_count; ++i) {
                    CUnit &u = UnitManager->GetSlotUnit(static_cast<int>(i));
                    if (u.IsAliveOnMap()
                        && u.Player == ThisPlayer
                        && static_cast<uint32_t>(UnitNumber(u)) == cmd.unit_id) {
                        target = &u;
                        break;
                    }
                }
                if (target) {
                    UnSelectAll();
                    SelectUnit(*target);
                    SelectedUnitChanged();
                    SendCommandMove(*target, dest, EFlushMode::On);
                }
            } else {
                // unit_id == 0: move all currently-selected units.
                for (CUnit *u : Selected) {
                    if (u && u->IsAliveOnMap() && u->Player == ThisPlayer) {
                        SendCommandMove(*u, dest, EFlushMode::On);
                    }
                }
            }
        } else if (cmd.type == PEONPAD_CMD_DESELECT_ALL) {
            // Clear the entire selection; matches Swift TabletopTransport.send(.deselectAll).
            UnSelectAll();
            SelectedUnitChanged();
        } else if (cmd.type == PEONPAD_CMD_STOP) {
            const unsigned slot_count = UnitManager->GetUsedSlotCount();
            for (unsigned i = 0; i < slot_count; ++i) {
                CUnit &u = UnitManager->GetSlotUnit(static_cast<int>(i));
                if (u.IsAliveOnMap()
                    && static_cast<uint32_t>(UnitNumber(u)) == cmd.unit_id
                    && u.Player == ThisPlayer) {
                    SendCommandStopUnit(u);
                    break;
                }
            }
        }
    }
}

// Capture the current game state and publish it as the new latest snapshot.
// Called from the simulation thread after GameLogicLoop().
void peonpad_tabletop_publish_snapshot(void)
{
    if (!g_bridge.initialized) return;
    if (!UnitManager) return;
    if (Map.Info.MapWidth <= 0 || Map.Info.MapHeight <= 0) return;

    const uint32_t mw = static_cast<uint32_t>(Map.Info.MapWidth);
    const uint32_t mh = static_cast<uint32_t>(Map.Info.MapHeight);
    if (mw > PEONPAD_TABLETOP_MAX_MAP_DIM || mh > PEONPAD_TABLETOP_MAX_MAP_DIM) return;

    auto *snap = new (std::nothrow) PeonPadSnapshot;
    if (!snap) return;

    snap->generation = static_cast<uint64_t>(GameCycle);
    snap->map_width  = mw;
    snap->map_height = mh;

    // ── Terrain + fog ───────────────────────────────────────────────────
    const uint32_t cell_count = mw * mh;
    snap->terrain.resize(cell_count);

    for (uint32_t y = 0; y < mh; ++y) {
        for (uint32_t x = 0; x < mw; ++x) {
            const CMapField *field = Map.Field(static_cast<int>(x),
                                               static_cast<int>(y));
            PeonPadTerrainCell &out = snap->terrain[y * mw + x];
            out.tile_index    = static_cast<uint16_t>(field->getTileIndex());
            out.terrain_class = ClassifyTerrain(field->getFlags());
            // Pixel-grid frame index into the tileset image (ABI v3), so the UI
            // can crop the real tile art from the tileset PNG.
            out.graphic_index = static_cast<uint16_t>(field->getGraphicTile());

            if (Map.NoFogOfWar || !ThisPlayer) {
                out.fog_state = static_cast<uint8_t>(PEONPAD_FOG_VISIBLE);
            } else {
                const CMapFieldPlayerInfo &info = field->playerInfo;
                if (info.IsTeamVisible(*ThisPlayer)) {
                    out.fog_state = static_cast<uint8_t>(PEONPAD_FOG_VISIBLE);
                } else if (info.IsExplored(*ThisPlayer)) {
                    out.fog_state = static_cast<uint8_t>(PEONPAD_FOG_EXPLORED);
                } else {
                    out.fog_state = static_cast<uint8_t>(PEONPAD_FOG_UNSEEN);
                }
            }
        }
    }

    // ── Tileset descriptor (ABI v3) ─────────────────────────────────────
    // The active map's tileset image + tile geometry, so terrain
    // `graphic_index` values map to a source rectangle in the tileset PNG.
    {
        const CTileset &ts = Map.Tileset;
        snap->has_tileset = true;
        // Prefer the fully-expanded tile graphic (base tileset PNG frames +
        // any procedurally-generated extended frames — see
        // ExportExpandedTilesetPNG above): every `graphic_index` the engine
        // can produce has a matching source rectangle in it, unlike the raw
        // authored PNG on disk. Fall back to the raw asset only if the
        // export failed (e.g. a write error), which is correct as long as
        // the current map references no extended/generated tile frames.
        uint16_t exported_width = 0, exported_height = 0;
        const std::string exported_tileset =
            ExportExpandedTilesetPNG(ts, exported_width, exported_height);
        std::string image_path;
        uint16_t image_width = 0, image_height = 0;
        if (!exported_tileset.empty()) {
            image_path   = exported_tileset;
            image_width  = exported_width;
            image_height = exported_height;
        } else {
            // CTileset::ImageFile stores the unresolved Lua path (e.g.
            // "tilesets/summer/terrain/summer.png") without the "graphics/"
            // prefix that the engine adds when loading.  Resolve via
            // LibraryFileName so the UI receives the staged-data-root-relative
            // path it can actually open (e.g. "graphics/tilesets/summer/…").
            image_path = ResolveAssetPath(ts.ImageFile);
        }
        std::snprintf(snap->tileset.image_path, PEONPAD_TABLETOP_MAX_PATH,
                      "%s", image_path.c_str());
        std::snprintf(snap->tileset.name, PEONPAD_TABLETOP_MAX_IDENT,
                      "%s", ts.Name.c_str());
        const PixelSize &pts = ts.getPixelTileSize();
        snap->tileset.pixel_tile_width  = static_cast<uint16_t>(pts.x);
        snap->tileset.pixel_tile_height = static_cast<uint16_t>(pts.y);
        // Known exactly when we exported the expanded graphic; otherwise left
        // 0 (unknown) and the UI derives the column count from the decoded
        // PNG's own dimensions (unchanged fallback behavior).
        snap->tileset.image_width  = image_width;
        snap->tileset.image_height = image_height;
    }

    // ── Units ────────────────────────────────────────────────────────────
    // Include: all own/allied units (always known to the local player);
    // enemy/neutral units only if currently visible (fog of war).
    // Dead own units are included (alive==0) so the UI can animate removal.
    // Dead enemy units outside visibility are omitted.
    const std::vector<CUnit *> &engine_units = UnitManager->GetUnits();
    snap->units.reserve(std::min(engine_units.size(),
                                 static_cast<size_t>(PEONPAD_TABLETOP_MAX_UNITS)));

    // Track which type_ids have already been added to the registry so each
    // distinct unit type contributes exactly one ident entry.
    std::vector<bool> type_seen;

    for (CUnit *u : engine_units) {
        if (!u) continue;
        if (snap->units.size() >= PEONPAD_TABLETOP_MAX_UNITS) break;

        const bool is_own = (ThisPlayer && u->Player == ThisPlayer);
        if (!is_own) {
            // Fog-of-war filter: skip enemy/neutral units that are not
            // currently visible to the local player.  Dead enemy units
            // that weren't visible are also excluded.
            if (!u->IsAliveOnMap()) continue;
            if (!Map.NoFogOfWar && ThisPlayer
                && !u->IsVisibleOnMap(*ThisPlayer)) continue;
        }

        PeonPadUnitRecord rec{};
        rec.id       = static_cast<uint32_t>(UnitNumber(*u));
        rec.owner    = u->Player ? static_cast<uint8_t>(u->Player->Index) : 0u;
        rec.alive    = u->IsAliveOnMap() ? 1u : 0u;
        rec.selected = u->Selected ? 1u : 0u;
        rec.facing   = u->Direction;
        rec.hp       = u->Variable[HP_INDEX].Value;
        rec.max_hp   = u->Variable[HP_INDEX].Max;
        rec.tile_x   = static_cast<int16_t>(u->tilePos.x);
        rec.tile_y   = static_cast<int16_t>(u->tilePos.y);
        rec.world_x  = static_cast<float>(u->IX);
        rec.world_y  = static_cast<float>(u->IY);
        rec.type_id  = u->Type ? static_cast<uint16_t>(u->Type->Slot) : 0u;
        if (u->Type) {
            // Engine-resolved sprite frame + mirror for the current facing +
            // animation (ABI v3), using the engine's own draw formula.
            ResolveSpriteFrame(*u->Type, u->Frame, rec.sprite_frame, rec.sprite_mirror);
        }

        // Register the unit type ident once per distinct type_id so the UI
        // can resolve real art without guessing from unit IDs.
        if (u->Type) {
            const size_t slot = static_cast<size_t>(u->Type->Slot);
            if (slot >= type_seen.size()) type_seen.resize(slot + 1, false);
            if (!type_seen[slot]
                && snap->unit_types.size() < PEONPAD_TABLETOP_MAX_UNIT_TYPES) {
                type_seen[slot] = true;
                PeonPadUnitType t{};
                t.type_id = rec.type_id;
                std::snprintf(t.ident, PEONPAD_TABLETOP_MAX_IDENT, "%s",
                              u->Type->Ident.c_str());
                // ABI v3 sprite metadata sourced from CUnitType so the UI can
                // locate and tint the real sprite sheet from staged data.
                // CUnitType::File stores the unresolved Lua path (e.g.
                // "orc/units/grunt.png") without the "graphics/" prefix;
                // resolve via LibraryFileName for the staged-data-relative path.
                const std::string resolved_sprite = ResolveAssetPath(u->Type->File);
                std::snprintf(t.sprite_path, PEONPAD_TABLETOP_MAX_PATH, "%s",
                              resolved_sprite.c_str());
                t.frame_width     = static_cast<uint16_t>(u->Type->Width);
                t.frame_height    = static_cast<uint16_t>(u->Type->Height);
                t.num_directions  = static_cast<uint8_t>(u->Type->NumDirections);
                t.flip            = u->Type->Flip ? 1u : 0u;
                t.team_color_start = static_cast<uint8_t>(PlayerColorIndexStart);
                t.team_color_count = static_cast<uint8_t>(PlayerColorIndexCount);
                // ABI v4 render category + tile footprint (engine-owned).
                // A resource-giving type (gold mine, oil patch) is a RESOURCE;
                // an otherwise-Building type is a BUILDING; else a MOBILE unit.
                if (u->Type->GivesResource != 0) {
                    t.render_category = PEONPAD_RENDER_RESOURCE;
                } else if (u->Type->Building) {
                    t.render_category = PEONPAD_RENDER_BUILDING;
                } else {
                    t.render_category = PEONPAD_RENDER_MOBILE;
                }
                t.tile_width  = static_cast<uint8_t>(
                    u->Type->TileWidth  > 0 ? u->Type->TileWidth  : 1);
                t.tile_height = static_cast<uint8_t>(
                    u->Type->TileHeight > 0 ? u->Type->TileHeight : 1);
                snap->unit_types.push_back(t);
            }
        }

        snap->units.push_back(rec);
    }

    PublishSnap(snap);
}

#else // PEONPAD_TABLETOP not defined ─ stub out the engine-only functions

void peonpad_tabletop_publish_snapshot(void) {}
void peonpad_tabletop_drain_commands(void) {}

#endif // PEONPAD_TABLETOP

} // extern "C"
