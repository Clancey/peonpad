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

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
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

static bool test_abi_version_constant()
{
    EXPECT(PEONPAD_TABLETOP_ABI_VERSION == 3u);
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

    // PeonPadUnitType (ABI v3): type_id(2) + _pad(2) + ident(32)
    //   + sprite_path(128) + frame_width(2) + frame_height(2)
    //   + num_directions(1) + flip(1) + team_color_start(1)
    //   + team_color_count(1) = 172 bytes
    EXPECT(sizeof(PeonPadUnitType) == 172u);

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

// ── main ──────────────────────────────────────────────────────────────────

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

    return AllPassed ? 0 : 1;
}
