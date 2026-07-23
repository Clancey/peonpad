// tabletop_bridge_test.cpp
//
// Unit and contract tests for PeonPadTabletopBridge.
//
// This binary is compiled WITHOUT PEONPAD_TABLETOP, so it never touches
// Stratagus global state.  All tests exercise the infrastructure through
// peonpad_tabletop_publish_synthetic(), which is always available.
//
// Test categories:
//   1. ABI layout contract  – struct sizes and field offsets are stable
//   2. Bridge lifecycle     – init / cleanup / double-init
//   3. Snapshot lifecycle   – synthetic publish, retain/release, NULL safety
//   4. Accessor functions   – all getters return correct values
//   5. Command validation   – post_command rejects malformed commands
//   6. Command round-trip   – valid commands are queued (drain is a no-op
//                              without PEONPAD_TABLETOP, but post returns 0)
//   7. Concurrent access    – retain+release from multiple notional threads

#include "PeonPadTabletopBridge.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

// ── Helpers ───────────────────────────────────────────────────────────────

#define EXPECT(condition) \
    do { \
        if (!(condition)) { \
            std::fprintf(stderr, \
                "FAIL [%s:%d] %s\n", __FILE__, __LINE__, #condition); \
            std::fflush(stderr); \
            return false; \
        } \
    } while (false)

static bool AllPassed = true;

static void Run(const char *name, bool (*test_fn)())
{
    const bool ok = test_fn();
    if (!ok) AllPassed = false;
    std::fprintf(stdout, "%s %s\n", ok ? "PASS" : "FAIL", name);
    std::fflush(stdout);
}

// ── 1. ABI layout contract ─────────────────────────────────────────────────

// Pure path/name helpers (TabletopTilesetPath.h/.cpp): no engine/SDL
// dependency, so they compile and link into this standalone host test
// binary. They back the engine-only expanded-tileset-PNG export
// (ExportExpandedTilesetPNG / TabletopExportTilesetSurfacePNG) that fixes
// the "wrong floor tiles" bug: Wargus tilesets append procedurally generated
// transition/cliff frames to the in-memory tile graphic (GenerateExtended
// Tileset -> CGraphic::AppendFrames), which have no matching pixels in the
// on-disk tileset PNG.
#include "TabletopTilesetPath.h"
#include "TabletopTilesetExportCache.h"

static bool test_abi_version_constant()
{
    EXPECT(PEONPAD_TABLETOP_ABI_VERSION == 4u);
    return true;
}

static bool test_struct_sizes()
{
    // PeonPadTerrainCell (ABI v3): tile_index(2) + fog_state(1)
    //   + terrain_class(1) + graphic_index(2) + _pad(2) = 8 bytes
    EXPECT(sizeof(PeonPadTerrainCell) == 8u);

    // PeonPadUnitRecord field layout (ABI v3, explicit accounting):
    //   id(4) + owner(1) + alive(1) + selected(1) + facing(1)
    //   + hp(4) + max_hp(4) + tile_x(2) + tile_y(2)
    //   + world_x(4) + world_y(4) + type_id(2) + sprite_frame(2)
    //   + sprite_mirror(1) + _pad3(3) = 36 bytes
    EXPECT(sizeof(PeonPadUnitRecord) == 36u);

    // PeonPadUnitType (ABI v4): type_id(2) + _pad(2) + ident(32)
    //   + sprite_path(128) + frame_width(2) + frame_height(2)
    //   + num_directions(1) + flip(1) + team_color_start(1)
    //   + team_color_count(1) + render_category(1) + tile_width(1)
    //   + tile_height(1) + _pad4(1) = 176 bytes
    EXPECT(sizeof(PeonPadUnitType) == 176u);

    // PeonPadTilesetDescriptor (ABI v3): image_path(128)
    //   + pixel_tile_width(2) + pixel_tile_height(2)
    //   + image_width(2) + image_height(2) + name(32) = 168 bytes
    EXPECT(sizeof(PeonPadTilesetDescriptor) == 168u);

    // PeonPadCommand:
    //   type(4) + abi_ver(4) + unit_id(4) + tile_x(4) + tile_y(4)
    //   + _reserved[8] = 28 bytes
    EXPECT(sizeof(PeonPadCommand) == 28u);

    return true;
}

static bool test_struct_field_offsets()
{
    EXPECT(offsetof(PeonPadTerrainCell, tile_index)    == 0u);
    EXPECT(offsetof(PeonPadTerrainCell, fog_state)     == 2u);
    EXPECT(offsetof(PeonPadTerrainCell, terrain_class) == 3u);
    EXPECT(offsetof(PeonPadTerrainCell, graphic_index) == 4u);

    EXPECT(offsetof(PeonPadUnitRecord, id)            ==  0u);
    EXPECT(offsetof(PeonPadUnitRecord, owner)         ==  4u);
    EXPECT(offsetof(PeonPadUnitRecord, alive)         ==  5u);
    EXPECT(offsetof(PeonPadUnitRecord, selected)      ==  6u);
    EXPECT(offsetof(PeonPadUnitRecord, facing)        ==  7u);
    EXPECT(offsetof(PeonPadUnitRecord, hp)            ==  8u);
    EXPECT(offsetof(PeonPadUnitRecord, max_hp)        == 12u);
    EXPECT(offsetof(PeonPadUnitRecord, tile_x)        == 16u);
    EXPECT(offsetof(PeonPadUnitRecord, tile_y)        == 18u);
    EXPECT(offsetof(PeonPadUnitRecord, world_x)       == 20u);
    EXPECT(offsetof(PeonPadUnitRecord, world_y)       == 24u);
    EXPECT(offsetof(PeonPadUnitRecord, type_id)       == 28u);
    EXPECT(offsetof(PeonPadUnitRecord, sprite_frame)  == 30u);
    EXPECT(offsetof(PeonPadUnitRecord, sprite_mirror) == 32u);

    EXPECT(offsetof(PeonPadUnitType, type_id)      == 0u);
    EXPECT(offsetof(PeonPadUnitType, ident)        == 4u);
    EXPECT(offsetof(PeonPadUnitType, sprite_path)  == 36u);
    // sprite_path is 128 bytes: 36 + 128 = 164.
    EXPECT(offsetof(PeonPadUnitType, frame_width)      == 164u);
    EXPECT(offsetof(PeonPadUnitType, frame_height)     == 166u);
    EXPECT(offsetof(PeonPadUnitType, num_directions)   == 168u);
    EXPECT(offsetof(PeonPadUnitType, flip)             == 169u);
    EXPECT(offsetof(PeonPadUnitType, team_color_start) == 170u);
    EXPECT(offsetof(PeonPadUnitType, team_color_count) == 171u);
    EXPECT(offsetof(PeonPadUnitType, render_category)  == 172u);
    EXPECT(offsetof(PeonPadUnitType, tile_width)       == 173u);
    EXPECT(offsetof(PeonPadUnitType, tile_height)      == 174u);

    EXPECT(offsetof(PeonPadTilesetDescriptor, image_path)        == 0u);
    EXPECT(offsetof(PeonPadTilesetDescriptor, pixel_tile_width)  == 128u);
    EXPECT(offsetof(PeonPadTilesetDescriptor, pixel_tile_height) == 130u);
    EXPECT(offsetof(PeonPadTilesetDescriptor, image_width)       == 132u);
    EXPECT(offsetof(PeonPadTilesetDescriptor, image_height)      == 134u);
    EXPECT(offsetof(PeonPadTilesetDescriptor, name)              == 136u);

    EXPECT(offsetof(PeonPadCommand, type)     ==  0u);
    EXPECT(offsetof(PeonPadCommand, abi_ver)  ==  4u);
    EXPECT(offsetof(PeonPadCommand, unit_id)  ==  8u);
    EXPECT(offsetof(PeonPadCommand, tile_x)   == 12u);
    EXPECT(offsetof(PeonPadCommand, tile_y)   == 16u);

    return true;
}

static bool test_enum_values()
{
    EXPECT(static_cast<int>(PEONPAD_FOG_UNSEEN)   == 0);
    EXPECT(static_cast<int>(PEONPAD_FOG_EXPLORED) == 1);
    EXPECT(static_cast<int>(PEONPAD_FOG_VISIBLE)  == 2);

    EXPECT(static_cast<int>(PEONPAD_TERRAIN_UNKNOWN) == 0);
    EXPECT(static_cast<int>(PEONPAD_TERRAIN_GRASS)   == 1);
    EXPECT(static_cast<int>(PEONPAD_TERRAIN_DIRT)    == 2);
    EXPECT(static_cast<int>(PEONPAD_TERRAIN_WATER)   == 3);
    EXPECT(static_cast<int>(PEONPAD_TERRAIN_ROCK)    == 4);
    EXPECT(static_cast<int>(PEONPAD_TERRAIN_FOREST)  == 5);
    EXPECT(static_cast<int>(PEONPAD_TERRAIN_COAST)   == 6);
    EXPECT(static_cast<int>(PEONPAD_TERRAIN_WALL)    == 7);

    EXPECT(static_cast<int>(PEONPAD_CMD_NONE)         == 0);
    EXPECT(static_cast<int>(PEONPAD_CMD_SELECT)       == 1);
    EXPECT(static_cast<int>(PEONPAD_CMD_DESELECT)     == 2);
    EXPECT(static_cast<int>(PEONPAD_CMD_MOVE)         == 3);
    EXPECT(static_cast<int>(PEONPAD_CMD_STOP)         == 4);
    EXPECT(static_cast<int>(PEONPAD_CMD_DESELECT_ALL) == 5);

    return true;
}

// ── 2. Bridge lifecycle ────────────────────────────────────────────────────

static bool test_init_cleanup()
{
    EXPECT(peonpad_tabletop_init() == 0);
    peonpad_tabletop_cleanup();

    // Second init after cleanup must succeed.
    EXPECT(peonpad_tabletop_init() == 0);
    // Double-init (without cleanup) must return -1.
    EXPECT(peonpad_tabletop_init() == -1);
    peonpad_tabletop_cleanup();
    return true;
}

static bool test_cleanup_without_init()
{
    // cleanup() must be safe without a prior init().
    peonpad_tabletop_cleanup();
    return true;
}

static bool test_no_snapshot_before_publish()
{
    EXPECT(peonpad_tabletop_init() == 0);
    EXPECT(peonpad_tabletop_latest_snapshot() == nullptr);
    peonpad_tabletop_cleanup();
    return true;
}

// ── 3. Snapshot lifecycle ─────────────────────────────────────────────────

static bool test_synthetic_publish_minimal()
{
    EXPECT(peonpad_tabletop_init() == 0);

    // Zero-size map, zero units.
    EXPECT(peonpad_tabletop_publish_synthetic(42, 0, 0, nullptr, 0, nullptr, 0) == 0);

    PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
    EXPECT(s != nullptr);
    EXPECT(peonpad_snapshot_generation(s) == 42u);
    EXPECT(peonpad_snapshot_map_width(s)  ==  0u);
    EXPECT(peonpad_snapshot_map_height(s) ==  0u);
    EXPECT(peonpad_snapshot_terrain_count(s) == 0u);
    EXPECT(peonpad_snapshot_terrain(s)    == nullptr);
    EXPECT(peonpad_snapshot_unit_count(s) ==  0u);
    EXPECT(peonpad_snapshot_units(s)      == nullptr);
    EXPECT(peonpad_snapshot_abi_version(s) == PEONPAD_TABLETOP_ABI_VERSION);

    peonpad_snapshot_release(s);
    peonpad_tabletop_cleanup();
    return true;
}

static bool test_synthetic_publish_with_terrain_and_units()
{
    EXPECT(peonpad_tabletop_init() == 0);

    constexpr uint32_t W = 3, H = 2;
    PeonPadTerrainCell terrain[W * H] = {};
    terrain[0] = {10, static_cast<uint8_t>(PEONPAD_FOG_VISIBLE),  0};
    terrain[1] = {11, static_cast<uint8_t>(PEONPAD_FOG_EXPLORED), 0};
    terrain[2] = {12, static_cast<uint8_t>(PEONPAD_FOG_UNSEEN),   0};
    terrain[3] = {20, static_cast<uint8_t>(PEONPAD_FOG_VISIBLE),  0};
    terrain[4] = {21, static_cast<uint8_t>(PEONPAD_FOG_VISIBLE),  0};
    terrain[5] = {22, static_cast<uint8_t>(PEONPAD_FOG_EXPLORED), 0};

    PeonPadUnitRecord units[2] = {};
    units[0].id       = 101;
    units[0].owner    = 0;
    units[0].alive    = 1;
    units[0].selected = 1;
    units[0].facing   = 0; // North
    units[0].hp       = 400;
    units[0].max_hp   = 400;
    units[0].tile_x   = 1;
    units[0].tile_y   = 0;
    units[0].world_x  = 0.5f;
    units[0].world_y  = 0.0f;

    units[1].id       = 202;
    units[1].owner    = 1;
    units[1].alive    = 0; // dead
    units[1].facing   = 128; // South
    units[1].hp       = 0;
    units[1].max_hp   = 900;
    units[1].tile_x   = 2;
    units[1].tile_y   = 1;

    EXPECT(peonpad_tabletop_publish_synthetic(
        999, W, H, terrain, W * H, units, 2) == 0);

    PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
    EXPECT(s != nullptr);
    EXPECT(peonpad_snapshot_generation(s)     == 999u);
    EXPECT(peonpad_snapshot_map_width(s)      == W);
    EXPECT(peonpad_snapshot_map_height(s)     == H);
    EXPECT(peonpad_snapshot_terrain_count(s)  == W * H);
    EXPECT(peonpad_snapshot_unit_count(s)     == 2u);

    const PeonPadTerrainCell *tc = peonpad_snapshot_terrain(s);
    EXPECT(tc != nullptr);
    EXPECT(tc[0].tile_index == 10);
    EXPECT(tc[0].fog_state  == static_cast<uint8_t>(PEONPAD_FOG_VISIBLE));
    EXPECT(tc[2].fog_state  == static_cast<uint8_t>(PEONPAD_FOG_UNSEEN));

    const PeonPadUnitRecord *ur = peonpad_snapshot_units(s);
    EXPECT(ur != nullptr);
    EXPECT(ur[0].id       == 101u);
    EXPECT(ur[0].alive    == 1u);
    EXPECT(ur[0].selected == 1u);
    EXPECT(ur[0].hp       == 400);
    EXPECT(ur[0].max_hp   == 400);
    EXPECT(ur[1].id       == 202u);
    EXPECT(ur[1].alive    == 0u);
    EXPECT(ur[1].facing   == 128u);

    peonpad_snapshot_release(s);
    peonpad_tabletop_cleanup();
    return true;
}

static bool test_synthetic_v2_unit_type_registry()
{
    EXPECT(peonpad_tabletop_init() == 0);

    PeonPadTerrainCell cell{5, static_cast<uint8_t>(PEONPAD_FOG_VISIBLE),
                            static_cast<uint8_t>(PEONPAD_TERRAIN_FOREST)};

    PeonPadUnitRecord units[2] = {};
    units[0].id = 1; units[0].alive = 1; units[0].type_id = 7;
    units[1].id = 2; units[1].alive = 1; units[1].type_id = 42;

    PeonPadUnitType types[2] = {};
    types[0].type_id = 7;
    std::snprintf(types[0].ident, PEONPAD_TABLETOP_MAX_IDENT, "unit-footman");
    types[1].type_id = 42;
    std::snprintf(types[1].ident, PEONPAD_TABLETOP_MAX_IDENT, "unit-grunt");

    EXPECT(peonpad_tabletop_publish_synthetic_v2(
        3, 1, 1, &cell, 1, units, 2, types, 2) == 0);

    PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
    EXPECT(s != nullptr);

    // Terrain class round-trips.
    const PeonPadTerrainCell *tc = peonpad_snapshot_terrain(s);
    EXPECT(tc != nullptr);
    EXPECT(tc[0].terrain_class == static_cast<uint8_t>(PEONPAD_TERRAIN_FOREST));

    // Unit type_id round-trips.
    const PeonPadUnitRecord *ur = peonpad_snapshot_units(s);
    EXPECT(ur != nullptr);
    EXPECT(ur[0].type_id == 7u);
    EXPECT(ur[1].type_id == 42u);

    // Type registry is present and correct.
    EXPECT(peonpad_snapshot_unit_type_count(s) == 2u);
    const PeonPadUnitType *ut = peonpad_snapshot_unit_types(s);
    EXPECT(ut != nullptr);
    EXPECT(ut[0].type_id == 7u);
    EXPECT(std::strcmp(ut[0].ident, "unit-footman") == 0);
    EXPECT(ut[1].type_id == 42u);
    EXPECT(std::strcmp(ut[1].ident, "unit-grunt") == 0);

    peonpad_snapshot_release(s);
    peonpad_tabletop_cleanup();
    return true;
}

static bool test_synthetic_v2_rejects_unterminated_ident()
{
    EXPECT(peonpad_tabletop_init() == 0);

    PeonPadUnitType type{};
    type.type_id = 1;
    // Fill the entire ident buffer with non-NUL bytes (not terminated).
    std::memset(type.ident, 'A', PEONPAD_TABLETOP_MAX_IDENT);

    EXPECT(peonpad_tabletop_publish_synthetic_v2(
        1, 0, 0, nullptr, 0, nullptr, 0, &type, 1) == -2);

    // v1 backward-compatibility: the legacy synthetic publish attaches an
    // empty type registry.
    EXPECT(peonpad_tabletop_publish_synthetic(1, 0, 0, nullptr, 0, nullptr, 0) == 0);
    PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
    EXPECT(s != nullptr);
    EXPECT(peonpad_snapshot_unit_type_count(s) == 0u);
    EXPECT(peonpad_snapshot_unit_types(s) == nullptr);

    peonpad_snapshot_release(s);
    peonpad_tabletop_cleanup();
    return true;
}

// Expanded-tileset export path/name helpers (pure, no engine dependency).
static bool test_expanded_tileset_cache_path()
{
    // Normal alphabetic tileset names pass through, lowercased.
    EXPECT(TabletopSanitizeTilesetCacheName("Forest") == "forest");
    EXPECT(TabletopSanitizeTilesetCacheName("Wasteland") == "wasteland");

    // Dashes/underscores are preserved; other punctuation and whitespace are
    // stripped so the display prefix is always a single safe path segment.
    EXPECT(TabletopSanitizeTilesetCacheName("Ice Cliffs-2") == "icecliffs-2");
    EXPECT(TabletopSanitizeTilesetCacheName("../etc/passwd") == "etcpasswd");

    // Degenerate input (empty, or sanitizes to nothing) falls back to a
    // stable, non-empty name rather than producing a malformed path.
    EXPECT(TabletopSanitizeTilesetCacheName("") == "tileset");
    EXPECT(TabletopSanitizeTilesetCacheName("   ") == "tileset");
    EXPECT(TabletopSanitizeTilesetCacheName("!!!") == "tileset");

    // TabletopTilesetExportRelativePath always lands under the fixed
    // "tabletop-generated/" subdirectory and ends in ".png".
    const std::string p1 = TabletopTilesetExportRelativePath("Forest", "tilesets/summer/terrain/summer.png", 1);
    EXPECT(p1.rfind("tabletop-generated/", 0) == 0);
    EXPECT(p1.size() > 4 && p1.compare(p1.size() - 4, 4, ".png") == 0);

    // Same (name, source, version) is deterministic (same filename every time).
    const std::string p1again = TabletopTilesetExportRelativePath(
        "Forest", "tilesets/summer/terrain/summer.png", 1);
    EXPECT(p1 == p1again);

    // A different version for the same tileset produces a different path
    // (so a reload that changed the underlying surface never reuses a
    // Swift-side cache entry keyed on the old path).
    const std::string p2 = TabletopTilesetExportRelativePath(
        "Forest", "tilesets/summer/terrain/summer.png", 2);
    EXPECT(p1 != p2);

    // Distinct tileset names never collide on the same cache path.
    const std::string winter = TabletopTilesetExportRelativePath(
        "Winter", "tilesets/winter/terrain/winter.png", 1);
    EXPECT(p1 != winter);

    // Two different tilesets whose *sanitized display prefixes* coincide
    // (e.g. "Ice Cliffs-2" and "IceCliffs-2" both sanitize to
    // "icecliffs-2") must still resolve to different paths — collision
    // resistance comes from hashing the full unsanitized identity, not the
    // sanitized display prefix.
    EXPECT(TabletopSanitizeTilesetCacheName("Ice Cliffs-2")
           == TabletopSanitizeTilesetCacheName("IceCliffs-2"));
    const std::string spaced = TabletopTilesetExportRelativePath(
        "Ice Cliffs-2", "tilesets/ice/terrain/ice.png", 1);
    const std::string nospace = TabletopTilesetExportRelativePath(
        "IceCliffs-2", "tilesets/ice/terrain/ice.png", 1);
    EXPECT(spaced != nospace);

    // Two tilesets with the *same name* but a different source image path
    // (an unusual but possible modded scenario) also never collide.
    const std::string sourceA = TabletopTilesetExportRelativePath(
        "Forest", "tilesets/summer/terrain/summer.png", 1);
    const std::string sourceB = TabletopTilesetExportRelativePath(
        "Forest", "tilesets/summer2/terrain/summer.png", 1);
    EXPECT(sourceA != sourceB);

    // Path length is always comfortably within PEONPAD_TABLETOP_MAX_PATH
    // (128 bytes including the NUL terminator), even for a pathologically
    // long/adversarial tileset name and a large version number.
    const std::string longName(500, 'A');
    const std::string longSource(500, '/');
    const std::string longPath = TabletopTilesetExportRelativePath(
        longName, longSource, 4000000000UL);
    EXPECT(longPath.size() + 1 <= PEONPAD_TABLETOP_MAX_PATH);
    EXPECT(longPath.rfind("tabletop-generated/", 0) == 0);

    // Degenerate (empty) identity still produces a safe, bounded path.
    const std::string emptyPath = TabletopTilesetExportRelativePath("", "", 0);
    EXPECT(emptyPath.size() + 1 <= PEONPAD_TABLETOP_MAX_PATH);
    EXPECT(emptyPath.rfind("tabletop-generated/", 0) == 0);

    return true;
}

// Reload/versioning/backoff decision logic (TabletopTilesetExportCache),
// exercised with synthetic identities (no real CGraphic/SDL needed) so the
// exact regression this PR fixes — a same-pointer, same-name tileset reload
// silently reusing a stale (too-small) export — is covered without engine
// linkage.
static bool test_tileset_export_cache_reload_and_backoff()
{
    TabletopTilesetExportCache cache;

    // First observation of a new identity: must export (never "use cached"
    // with nothing yet cached).
    auto d1 = cache.Attempt(/*graphicIdentity=*/0x1000, "Winter", 512, 768,
                             /*currentGameCycle=*/0, /*retryBackoffTicks=*/300);
    EXPECT(d1.action == TabletopTilesetExportAction::Export);
    EXPECT(d1.version == 1);
    cache.RecordSuccess("tabletop-generated/winter-v1-aaaa.png", 512, 768);

    // Same identity again (same pointer, name, dims): must reuse the cache,
    // no re-export.
    auto d2 = cache.Attempt(0x1000, "Winter", 512, 768, 10, 300);
    EXPECT(d2.action == TabletopTilesetExportAction::UseCached);
    EXPECT(d2.cachedRelativePath == "tabletop-generated/winter-v1-aaaa.png");
    EXPECT(d2.cachedWidth == 512);
    EXPECT(d2.cachedHeight == 768);

    // The exact regression this cache exists to prevent: the *same*
    // CGraphic pointer and tileset name reload for a different map, but
    // GenerateExtendedTileset() ran again and grew the surface taller (a
    // same-pointer, same-name, *different-dimensions* reload). Must be
    // treated as a brand-new export, not served from the stale cache.
    auto d3 = cache.Attempt(0x1000, "Winter", 512, 900, 20, 300);
    EXPECT(d3.action == TabletopTilesetExportAction::Export);
    EXPECT(d3.version == 2); // bumped: a new filename, never reusing v1's.
    cache.RecordSuccess("tabletop-generated/winter-v2-bbbb.png", 512, 900);

    // The new (larger) generation is now what's cached.
    auto d4 = cache.Attempt(0x1000, "Winter", 512, 900, 25, 300);
    EXPECT(d4.action == TabletopTilesetExportAction::UseCached);
    EXPECT(d4.cachedRelativePath == "tabletop-generated/winter-v2-bbbb.png");
    EXPECT(d4.cachedHeight == 900);

    // A different CGraphic pointer with the same name/dims is also a new
    // identity (defense in depth — distinct tileset instances never share a
    // cache entry just because their name/dims happen to match).
    auto d5 = cache.Attempt(0x2000, "Winter", 512, 900, 30, 300);
    EXPECT(d5.action == TabletopTilesetExportAction::Export);
    EXPECT(d5.version == 3);

    return true;
}

static bool test_tileset_export_cache_failure_backoff()
{
    TabletopTilesetExportCache cache;

    auto d1 = cache.Attempt(0x1000, "Forest", 256, 256, /*currentGameCycle=*/0, /*retryBackoffTicks=*/300);
    EXPECT(d1.action == TabletopTilesetExportAction::Export);
    cache.RecordFailure(/*currentGameCycle=*/0);

    // Same identity, shortly after the failure: back off rather than
    // retrying the write (and directory-creation attempt) every tick.
    auto d2 = cache.Attempt(0x1000, "Forest", 256, 256, /*currentGameCycle=*/10, 300);
    EXPECT(d2.action == TabletopTilesetExportAction::Backoff);
    auto d3 = cache.Attempt(0x1000, "Forest", 256, 256, /*currentGameCycle=*/299, 300);
    EXPECT(d3.action == TabletopTilesetExportAction::Backoff);

    // Once the backoff window elapses, retry — at the *same* version, since
    // the identity (and therefore target filename) hasn't changed.
    auto d4 = cache.Attempt(0x1000, "Forest", 256, 256, /*currentGameCycle=*/300, 300);
    EXPECT(d4.action == TabletopTilesetExportAction::Export);
    EXPECT(d4.version == d1.version);

    // A retry can succeed: subsequent identical calls then hit the fast
    // cached path instead of ever retrying again.
    cache.RecordSuccess("tabletop-generated/forest-v1-cccc.png", 256, 256);
    auto d5 = cache.Attempt(0x1000, "Forest", 256, 256, /*currentGameCycle=*/1000, 300);
    EXPECT(d5.action == TabletopTilesetExportAction::UseCached);

    // An identity change immediately after a failure is *not* subject to
    // backoff (backoff only applies to retrying the *same* failing
    // identity) — a genuinely new tileset must still get its chance.
    TabletopTilesetExportCache cache2;
    auto e1 = cache2.Attempt(0x3000, "Swamp", 128, 128, 0, 300);
    EXPECT(e1.action == TabletopTilesetExportAction::Export);
    cache2.RecordFailure(0);
    auto e2 = cache2.Attempt(0x4000, "Swamp", 128, 128, 1, 300);
    EXPECT(e2.action == TabletopTilesetExportAction::Export);

    return true;
}

static bool test_synthetic_v3_asset_descriptors()
{
    EXPECT(peonpad_tabletop_init() == 0);

    // Terrain carries the v3 graphic_index (pixel-grid frame in the tileset).
    PeonPadTerrainCell cell{};
    cell.tile_index    = 12u;
    cell.fog_state     = static_cast<uint8_t>(PEONPAD_FOG_VISIBLE);
    cell.terrain_class = static_cast<uint8_t>(PEONPAD_TERRAIN_GRASS);
    cell.graphic_index = 329u;

    // Units carry the v3 resolved sprite_frame + sprite_mirror.
    PeonPadUnitRecord units[1] = {};
    units[0].id = 1; units[0].alive = 1; units[0].type_id = 7;
    units[0].sprite_frame = 45u;
    units[0].sprite_mirror = 1u;

    // Unit type carries the v3 sprite metadata.
    PeonPadUnitType types[1] = {};
    types[0].type_id = 7;
    std::snprintf(types[0].ident, PEONPAD_TABLETOP_MAX_IDENT, "unit-footman");
    std::snprintf(types[0].sprite_path, PEONPAD_TABLETOP_MAX_PATH,
                  "human/units/footman.png");
    types[0].frame_width      = 72u;
    types[0].frame_height     = 72u;
    types[0].num_directions   = 5u;
    types[0].flip             = 1u;
    types[0].team_color_start = 208u;
    types[0].team_color_count = 4u;
    // ABI v4: a 4×4 building footprint, resource category.
    types[0].render_category  = PEONPAD_RENDER_RESOURCE;
    types[0].tile_width       = 3u;
    types[0].tile_height      = 3u;

    PeonPadTilesetDescriptor tileset{};
    std::snprintf(tileset.image_path, PEONPAD_TABLETOP_MAX_PATH,
                  "tilesets/summer/terrain/summer.png");
    std::snprintf(tileset.name, PEONPAD_TABLETOP_MAX_IDENT, "Forest");
    tileset.pixel_tile_width  = 32u;
    tileset.pixel_tile_height = 32u;

    EXPECT(peonpad_tabletop_publish_synthetic_v3(
        9, 1, 1, &cell, 1, units, 1, types, 1, &tileset) == 0);

    PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
    EXPECT(s != nullptr);
    EXPECT(peonpad_snapshot_abi_version(s) == PEONPAD_TABLETOP_ABI_VERSION);

    // Terrain graphic_index round-trips.
    const PeonPadTerrainCell *tc = peonpad_snapshot_terrain(s);
    EXPECT(tc != nullptr);
    EXPECT(tc[0].graphic_index == 329u);

    // Unit sprite frame + mirror round-trip.
    const PeonPadUnitRecord *ur = peonpad_snapshot_units(s);
    EXPECT(ur != nullptr);
    EXPECT(ur[0].sprite_frame == 45u);
    EXPECT(ur[0].sprite_mirror == 1u);

    // Unit-type sprite metadata round-trips.
    const PeonPadUnitType *ut = peonpad_snapshot_unit_types(s);
    EXPECT(ut != nullptr);
    EXPECT(std::strcmp(ut[0].sprite_path, "human/units/footman.png") == 0);
    EXPECT(ut[0].frame_width == 72u);
    EXPECT(ut[0].frame_height == 72u);
    EXPECT(ut[0].num_directions == 5u);
    EXPECT(ut[0].flip == 1u);
    EXPECT(ut[0].team_color_start == 208u);
    EXPECT(ut[0].team_color_count == 4u);
    // ABI v4 render category + footprint round-trip.
    EXPECT(ut[0].render_category == PEONPAD_RENDER_RESOURCE);
    EXPECT(ut[0].tile_width == 3u);
    EXPECT(ut[0].tile_height == 3u);

    // Tileset descriptor round-trips.
    const PeonPadTilesetDescriptor *td = peonpad_snapshot_tileset(s);
    EXPECT(td != nullptr);
    EXPECT(std::strcmp(td->image_path, "tilesets/summer/terrain/summer.png") == 0);
    EXPECT(std::strcmp(td->name, "Forest") == 0);
    EXPECT(td->pixel_tile_width == 32u);
    EXPECT(td->pixel_tile_height == 32u);

    peonpad_snapshot_release(s);

    // A v1/v2 publish attaches no tileset descriptor.
    EXPECT(peonpad_tabletop_publish_synthetic(1, 0, 0, nullptr, 0, nullptr, 0) == 0);
    PeonPadSnapshot *s2 = peonpad_tabletop_latest_snapshot();
    EXPECT(s2 != nullptr);
    EXPECT(peonpad_snapshot_tileset(s2) == nullptr);
    peonpad_snapshot_release(s2);

    peonpad_tabletop_cleanup();
    return true;
}

static bool test_synthetic_v3_rejects_unterminated_paths()
{
    EXPECT(peonpad_tabletop_init() == 0);

    // Unterminated sprite_path is rejected.
    PeonPadUnitType type{};
    type.type_id = 1;
    std::snprintf(type.ident, PEONPAD_TABLETOP_MAX_IDENT, "unit-x");
    std::memset(type.sprite_path, 'A', PEONPAD_TABLETOP_MAX_PATH);
    EXPECT(peonpad_tabletop_publish_synthetic_v3(
        1, 0, 0, nullptr, 0, nullptr, 0, &type, 1, nullptr) == -2);

    // Unterminated tileset image_path is rejected.
    PeonPadTilesetDescriptor tileset{};
    std::memset(tileset.image_path, 'B', PEONPAD_TABLETOP_MAX_PATH);
    std::snprintf(tileset.name, PEONPAD_TABLETOP_MAX_IDENT, "T");
    EXPECT(peonpad_tabletop_publish_synthetic_v3(
        1, 0, 0, nullptr, 0, nullptr, 0, nullptr, 0, &tileset) == -2);

    peonpad_tabletop_cleanup();
    return true;
}

static bool test_retain_release()
{
    EXPECT(peonpad_tabletop_init() == 0);
    EXPECT(peonpad_tabletop_publish_synthetic(1, 0, 0, nullptr, 0, nullptr, 0) == 0);

    PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot(); // refcount == 2
    EXPECT(s != nullptr);
    EXPECT(peonpad_snapshot_retain(s) == 0); // refcount == 3
    peonpad_snapshot_release(s);             // refcount == 2
    peonpad_snapshot_release(s);             // refcount == 1 (bridge still holds it)

    // Publishing a new snapshot drops the bridge's reference to the old one.
    EXPECT(peonpad_tabletop_publish_synthetic(2, 0, 0, nullptr, 0, nullptr, 0) == 0);
    PeonPadSnapshot *s2 = peonpad_tabletop_latest_snapshot();
    EXPECT(s2 != nullptr);
    EXPECT(peonpad_snapshot_generation(s2) == 2u);
    peonpad_snapshot_release(s2);

    peonpad_tabletop_cleanup();
    return true;
}

static bool test_null_safety()
{
    // All accessor functions must tolerate NULL without crashing.
    EXPECT(peonpad_snapshot_abi_version(nullptr)   == 0u);
    EXPECT(peonpad_snapshot_generation(nullptr)    == 0u);
    EXPECT(peonpad_snapshot_map_width(nullptr)     == 0u);
    EXPECT(peonpad_snapshot_map_height(nullptr)    == 0u);
    EXPECT(peonpad_snapshot_terrain_count(nullptr) == 0u);
    EXPECT(peonpad_snapshot_terrain(nullptr)       == nullptr);
    EXPECT(peonpad_snapshot_unit_count(nullptr)    == 0u);
    EXPECT(peonpad_snapshot_units(nullptr)         == nullptr);
    EXPECT(peonpad_snapshot_retain(nullptr)        == -1);
    peonpad_snapshot_release(nullptr); // must not crash

    return true;
}

static bool test_snapshot_data_is_immutable_copy()
{
    EXPECT(peonpad_tabletop_init() == 0);

    PeonPadTerrainCell cell{77, static_cast<uint8_t>(PEONPAD_FOG_VISIBLE), 0};
    EXPECT(peonpad_tabletop_publish_synthetic(
        10, 1, 1, &cell, 1, nullptr, 0) == 0);

    PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
    EXPECT(s != nullptr);

    // Mutate the original cell — snapshot must not change.
    cell.tile_index = 99;
    EXPECT(peonpad_snapshot_terrain(s)[0].tile_index == 77u);

    peonpad_snapshot_release(s);
    peonpad_tabletop_cleanup();
    return true;
}

// ── 4. Synthetic publish validation ───────────────────────────────────────

static bool test_publish_rejects_count_mismatch()
{
    EXPECT(peonpad_tabletop_init() == 0);

    // terrain_count must equal map_width * map_height
    PeonPadTerrainCell cell{};
    EXPECT(peonpad_tabletop_publish_synthetic(0, 2, 2, &cell, 3, nullptr, 0) == -2);
    EXPECT(peonpad_tabletop_publish_synthetic(0, 2, 2, nullptr, 0, nullptr, 0) == -2);

    // unit_count exceeds hard limit
    EXPECT(peonpad_tabletop_publish_synthetic(
        0, 0, 0, nullptr, 0, nullptr,
        PEONPAD_TABLETOP_MAX_UNITS + 1) == -2);

    // Non-zero count with NULL pointer
    EXPECT(peonpad_tabletop_publish_synthetic(0, 1, 1, nullptr, 1, nullptr, 0) == -2);

    peonpad_tabletop_cleanup();
    return true;
}

static bool test_publish_not_initialized()
{
    // Bridge not initialized: all publish functions return -1.
    EXPECT(peonpad_tabletop_publish_synthetic(
        0, 0, 0, nullptr, 0, nullptr, 0) == -1);
    EXPECT(peonpad_tabletop_latest_snapshot() == nullptr);
    return true;
}

// ── 5. Command validation ─────────────────────────────────────────────────

static bool test_command_null_rejected()
{
    EXPECT(peonpad_tabletop_init() == 0);
    EXPECT(peonpad_tabletop_post_command(nullptr) == -2);
    peonpad_tabletop_cleanup();
    return true;
}

static bool test_command_wrong_abi_version()
{
    EXPECT(peonpad_tabletop_init() == 0);
    PeonPadCommand cmd{};
    cmd.type    = PEONPAD_CMD_SELECT;
    cmd.abi_ver = PEONPAD_TABLETOP_ABI_VERSION + 1; // wrong version
    cmd.unit_id = 1;
    EXPECT(peonpad_tabletop_post_command(&cmd) == -2);
    peonpad_tabletop_cleanup();
    return true;
}

static bool test_command_unknown_type()
{
    EXPECT(peonpad_tabletop_init() == 0);
    PeonPadCommand cmd{};
    cmd.type    = 99; // unknown
    cmd.abi_ver = PEONPAD_TABLETOP_ABI_VERSION;
    EXPECT(peonpad_tabletop_post_command(&cmd) == -2);
    peonpad_tabletop_cleanup();
    return true;
}

static bool test_command_move_out_of_range()
{
    EXPECT(peonpad_tabletop_init() == 0);
    PeonPadCommand cmd{};
    cmd.type    = PEONPAD_CMD_MOVE;
    cmd.abi_ver = PEONPAD_TABLETOP_ABI_VERSION;
    cmd.tile_x  = -1; // negative
    cmd.tile_y  = 0;
    EXPECT(peonpad_tabletop_post_command(&cmd) == -2);

    cmd.tile_x = 0;
    cmd.tile_y = static_cast<int32_t>(PEONPAD_TABLETOP_MAX_MAP_DIM); // too large
    EXPECT(peonpad_tabletop_post_command(&cmd) == -2);

    peonpad_tabletop_cleanup();
    return true;
}

static bool test_command_not_initialized()
{
    PeonPadCommand cmd{};
    cmd.type    = PEONPAD_CMD_SELECT;
    cmd.abi_ver = PEONPAD_TABLETOP_ABI_VERSION;
    cmd.unit_id = 1;
    EXPECT(peonpad_tabletop_post_command(&cmd) == -1);
    return true;
}

// ── 6. Command round-trip ─────────────────────────────────────────────────

static bool test_valid_commands_accepted()
{
    EXPECT(peonpad_tabletop_init() == 0);

    PeonPadCommand cmd{};
    cmd.abi_ver = PEONPAD_TABLETOP_ABI_VERSION;

    cmd.type    = PEONPAD_CMD_SELECT;
    cmd.unit_id = 42;
    EXPECT(peonpad_tabletop_post_command(&cmd) == 0);

    cmd.type    = PEONPAD_CMD_DESELECT;
    cmd.unit_id = 42;
    EXPECT(peonpad_tabletop_post_command(&cmd) == 0);

    cmd.type   = PEONPAD_CMD_MOVE;
    cmd.tile_x = 10;
    cmd.tile_y = 20;
    EXPECT(peonpad_tabletop_post_command(&cmd) == 0);

    cmd.type    = PEONPAD_CMD_STOP;
    cmd.unit_id = 42;
    EXPECT(peonpad_tabletop_post_command(&cmd) == 0);

    // DESELECT_ALL: unit_id irrelevant — accepted when bridge is initialized.
    cmd.type    = PEONPAD_CMD_DESELECT_ALL;
    cmd.unit_id = 0;
    EXPECT(peonpad_tabletop_post_command(&cmd) == 0);

    // MOVE with explicit unit_id: targets a specific unit rather than the
    // current selection.  Accepted as long as coords are in range.
    cmd.type    = PEONPAD_CMD_MOVE;
    cmd.unit_id = 99;
    cmd.tile_x  = 5;
    cmd.tile_y  = 7;
    EXPECT(peonpad_tabletop_post_command(&cmd) == 0);

    // drain_commands is a no-op without PEONPAD_TABLETOP but must not crash.
    peonpad_tabletop_drain_commands();

    peonpad_tabletop_cleanup();
    return true;
}

static bool test_command_queue_full()
{
    EXPECT(peonpad_tabletop_init() == 0);

    PeonPadCommand cmd{};
    cmd.type    = PEONPAD_CMD_STOP;
    cmd.abi_ver = PEONPAD_TABLETOP_ABI_VERSION;
    cmd.unit_id = 1;

    for (uint32_t i = 0; i < PEONPAD_TABLETOP_MAX_COMMANDS; ++i) {
        EXPECT(peonpad_tabletop_post_command(&cmd) == 0);
    }
    // One over the limit must return -3.
    EXPECT(peonpad_tabletop_post_command(&cmd) == -3);

    peonpad_tabletop_cleanup();
    return true;
}

// ── 7. Concurrent access ──────────────────────────────────────────────────

static bool test_concurrent_retain_release()
{
    EXPECT(peonpad_tabletop_init() == 0);
    EXPECT(peonpad_tabletop_publish_synthetic(77, 0, 0, nullptr, 0, nullptr, 0) == 0);

    PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
    EXPECT(s != nullptr);

    // Two threads each retain+release the same snapshot simultaneously.
    auto worker = [s]() {
        for (int i = 0; i < 1000; ++i) {
            peonpad_snapshot_retain(s);
            peonpad_snapshot_release(s);
        }
    };
    std::thread t1(worker);
    std::thread t2(worker);
    t1.join();
    t2.join();

    // The original caller's reference is still valid; release it.
    peonpad_snapshot_release(s);

    peonpad_tabletop_cleanup();
    return true;
}

static bool test_concurrent_latest_snapshot()
{
    EXPECT(peonpad_tabletop_init() == 0);
    EXPECT(peonpad_tabletop_publish_synthetic(1, 0, 0, nullptr, 0, nullptr, 0) == 0);

    // One thread continuously publishes new snapshots; another calls
    // latest_snapshot + release.  Both must complete without data races.
    std::atomic<bool> stop{false};
    uint64_t gen = 2;

    std::thread publisher([&]() {
        while (!stop.load(std::memory_order_relaxed)) {
            peonpad_tabletop_publish_synthetic(gen++, 0, 0, nullptr, 0, nullptr, 0);
        }
    });

    std::thread reader([&]() {
        for (int i = 0; i < 2000; ++i) {
            PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
            if (s) peonpad_snapshot_release(s);
        }
    });

    reader.join();
    stop.store(true, std::memory_order_relaxed);
    publisher.join();

    peonpad_tabletop_cleanup();
    return true;
}

// ── Concurrency: publish_synthetic_v3 vs cleanup race ────────────────────
// Regression for the TOCTOU where publish_synthetic_v3 checked initialized,
// released cmd_mutex, then cleanup() ran fully, and then PublishSnap set a
// non-null latest on a shut-down bridge (memory leak + broken invariant).
static bool test_concurrent_publish_cleanup()
{
    // Run many iterations to exercise the race window.
    for (int iter = 0; iter < 200; ++iter) {
        EXPECT(peonpad_tabletop_init() == 0);

        std::atomic<bool> cleanup_done{false};

        // Publisher thread: publish synthetic snapshots until cleanup completes.
        std::thread publisher([&]() {
            while (!cleanup_done.load(std::memory_order_acquire)) {
                peonpad_tabletop_publish_synthetic(1, 0, 0, nullptr, 0, nullptr, 0);
            }
        });

        // Small delay to let the publisher thread start, then call cleanup.
        std::this_thread::sleep_for(std::chrono::microseconds(10));
        peonpad_tabletop_cleanup();
        cleanup_done.store(true, std::memory_order_release);
        publisher.join();

        // After cleanup: latest_snapshot must return nullptr — no stale
        // snapshot leaked from a post-cleanup publish.
        PeonPadSnapshot *s = peonpad_tabletop_latest_snapshot();
        EXPECT(s == nullptr);
    }
    return true;
}



int main()
{
    // ABI layout
    Run("abi_version_constant",     test_abi_version_constant);
    Run("struct_sizes",             test_struct_sizes);
    Run("struct_field_offsets",     test_struct_field_offsets);
    Run("enum_values",              test_enum_values);

    // Lifecycle
    Run("init_cleanup",             test_init_cleanup);
    Run("cleanup_without_init",     test_cleanup_without_init);
    Run("no_snapshot_before_pub",   test_no_snapshot_before_publish);

    // Snapshot
    Run("synthetic_publish_min",    test_synthetic_publish_minimal);
    Run("synthetic_publish_full",   test_synthetic_publish_with_terrain_and_units);
    Run("synthetic_v2_type_registry", test_synthetic_v2_unit_type_registry);
    Run("synthetic_v2_bad_ident",   test_synthetic_v2_rejects_unterminated_ident);
    Run("synthetic_v3_descriptors", test_synthetic_v3_asset_descriptors);
    Run("synthetic_v3_bad_paths",   test_synthetic_v3_rejects_unterminated_paths);
    Run("expanded_tileset_cache_path", test_expanded_tileset_cache_path);
    Run("tileset_export_cache_reload", test_tileset_export_cache_reload_and_backoff);
    Run("tileset_export_cache_backoff", test_tileset_export_cache_failure_backoff);
    Run("retain_release",           test_retain_release);
    Run("null_safety",              test_null_safety);
    Run("data_is_immutable_copy",   test_snapshot_data_is_immutable_copy);

    // Validation
    Run("publish_count_mismatch",   test_publish_rejects_count_mismatch);
    Run("publish_not_initialized",  test_publish_not_initialized);

    // Commands
    Run("cmd_null_rejected",        test_command_null_rejected);
    Run("cmd_wrong_abi_version",    test_command_wrong_abi_version);
    Run("cmd_unknown_type",         test_command_unknown_type);
    Run("cmd_move_out_of_range",    test_command_move_out_of_range);
    Run("cmd_not_initialized",      test_command_not_initialized);
    Run("valid_commands_accepted",  test_valid_commands_accepted);
    Run("command_queue_full",       test_command_queue_full);

    // Concurrency
    Run("concurrent_retain_release",test_concurrent_retain_release);
    Run("concurrent_latest_snap",   test_concurrent_latest_snapshot);
    Run("concurrent_publish_cleanup", test_concurrent_publish_cleanup);

    return AllPassed ? 0 : 1;
}
