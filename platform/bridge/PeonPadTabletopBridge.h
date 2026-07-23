// PeonPadTabletopBridge.h
//
// Engine-side C ABI for the visionOS live tabletop bridge.
//
// This header is language-neutral and safe to include from Swift via an
// Objective-C++ bridging header.  It contains no C++ types, no SDL types,
// and no Stratagus-internal types.
//
// ABI contract
// ────────────
//   • Version: PEONPAD_TABLETOP_ABI_VERSION  (bump on any struct layout or
//     semantic change; consumers must check before trusting field offsets).
//   • Snapshots are immutable once published and are reference-counted.
//     The caller must retain before sharing across thread boundaries and
//     release when done.  The bridge holds one internal reference; it is
//     dropped when a newer snapshot is published.
//   • Commands are posted from any thread into a bounded queue and processed
//     by the simulation thread on its next game tick.
//   • All public functions are null-safe: passing a NULL pointer returns a
//     defined error (0 / -1 / NULL) rather than crashing.
//
// Thread safety
// ─────────────
//   peonpad_tabletop_publish_snapshot()   ← simulation thread only
//   peonpad_tabletop_drain_commands()     ← simulation thread only
//   peonpad_tabletop_latest_snapshot()    ← any thread (UI thread typical)
//   peonpad_snapshot_retain/release()     ← any thread
//   peonpad_tabletop_post_command()       ← any thread (UI thread typical)
//   peonpad_tabletop_init/cleanup()       ← call from simulation thread

#pragma once
#ifndef PEONPAD_TABLETOP_BRIDGE_H
#define PEONPAD_TABLETOP_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ── ABI version ─────────────────────────────────────────────────────────────

/// Increment any time a struct layout or semantic changes.
/// Consumers check this before trusting field offsets.
///
/// ABI v2 (backward-compatible extension of v1):
///   • PeonPadTerrainCell: the former reserved `_pad` byte is now
///     `terrain_class` (a PeonPadTerrainClass).  Field offsets and struct
///     size are unchanged, so a v1 consumer reading terrain sees a zero
///     (PEONPAD_TERRAIN_UNKNOWN) where it previously saw the reserved pad.
///   • PeonPadUnitRecord: appends `type_id` (+ reserved padding) after the
///     v1 fields.  Existing field offsets are unchanged; the struct grows.
///   • New snapshot unit-type registry maps `type_id` → engine ident string
///     so the UI can resolve real unit art without guessing from unit IDs.
/// Consumers must check peonpad_snapshot_abi_version() before trusting the
/// v2 fields; a v1-only consumer can still read every v1 field safely.
///
/// ABI v3 (asset-descriptor extension of v2):
///   • PeonPadTerrainCell: appends `graphic_index` (+ reserved padding) — the
///     pixel-grid frame index of this tile within the tileset image, so the UI
///     can crop the real tile art.  v1/v2 field offsets are unchanged; the
///     struct grows from 4 to 8 bytes.
///   • PeonPadUnitRecord: repurposes the v2 reserved `_pad2` as `sprite_frame`
///     and appends `sprite_mirror` (+ reserved padding) — the engine-resolved
///     sprite-sheet frame index and horizontal-mirror flag for this unit's
///     current facing/animation, computed with the engine's own draw formula
///     (never re-derived in Swift/Lua).  v1/v2 field offsets are unchanged.
///   • PeonPadUnitType: appends the unit's sprite metadata (relative sprite
///     path, frame size, direction count, flip flag, team-color palette span)
///     so the UI can locate and tint the real sprite sheet.  v2 offsets
///     (type_id, ident) are unchanged.
///   • New PeonPadTilesetDescriptor (one per snapshot): the tileset image path,
///     pixel tile size, and image dimensions, so terrain `graphic_index` maps
///     to a source rectangle without guessing the tileset layout.
/// All v3 additions are engine-owned metadata sourced from CTileset/CUnitType;
/// the UI resolves real art from the staged read-only data directory at runtime
/// and never embeds proprietary assets.  A v2 consumer must discard a v3
/// snapshot (the version differs), so struct growth is safe.
///
/// ABI v4 (render-category + footprint extension of v3):
///   • PeonPadUnitType: appends `render_category` (PeonPadRenderCategory:
///     mobile / building / resource, sourced from CUnitType::Building and
///     GivesResource) and the unit type's tile footprint `tile_width` /
///     `tile_height` (from CUnitType::TileWidth/TileHeight), plus a reserved
///     pad.  v3 offsets (through team_color_count) are unchanged; the struct
///     grows from 172 to 176 bytes.  This lets the UI render buildings and
///     resources at their true map footprint/scale and keep them map-oriented
///     (they are non-directional, so they never re-orient toward the camera),
///     while mobile units keep their camera-relative directional sprites.
/// A v3 consumer must discard a v4 snapshot (the version differs), so the
/// PeonPadUnitType growth is safe.
///
/// ABI v5 (tileset path-root discriminator, extension of v4):
///   • PeonPadTilesetDescriptor: appends `image_path_root`
///     (PeonPadTilesetPathRoot: which root `image_path` is relative to) plus
///     a reserved pad.  v4 offsets (through `name`) are unchanged; the
///     struct grows from 168 to 170 bytes.
///
///     Why this exists: the engine can export a fully-expanded tileset PNG
///     (see PeonPadTabletopBridge.cpp's ExportExpandedTilesetPNG) to fix
///     terrain tiles whose `graphic_index` references a procedurally
///     generated frame that only exists in the engine's in-memory tile
///     graphic, never on disk. That exported file lives under the writable
///     user/cache root (`-u`), not the read-only staged game-data root
///     (`-d`) that `image_path` was previously *always* relative to (and
///     that this header, before v5, still documented as the only
///     possibility). A v4 (or earlier) consumer has no way to know which
///     root a v5 `image_path` is relative to and would resolve a
///     cache-relative path against the data root, silently failing to find
///     the file (or, if a same-named file coincidentally existed there,
///     resolving the wrong one) — a real behavioral break, not just a
///     struct-layout one, so the version bump is required even though no
///     prior field moved.
/// A v4 consumer must discard a v5 snapshot (the version differs), so the
/// PeonPadTilesetDescriptor growth is safe.
#define PEONPAD_TABLETOP_ABI_VERSION 5u

// ── Hard limits ─────────────────────────────────────────────────────────────

/// Maximum side length of a supported map (matches Stratagus MaxMapWidth/Height).
#define PEONPAD_TABLETOP_MAX_MAP_DIM  1024u
/// Maximum number of units in a single snapshot.
#define PEONPAD_TABLETOP_MAX_UNITS    4096u
/// Maximum pending commands in the intake queue.
#define PEONPAD_TABLETOP_MAX_COMMANDS 256u
/// Maximum length (including the terminating NUL) of a unit-type identifier.
#define PEONPAD_TABLETOP_MAX_IDENT    32u
/// Maximum number of distinct unit types in a snapshot's type registry.
#define PEONPAD_TABLETOP_MAX_UNIT_TYPES 512u
/// Maximum length (including the terminating NUL) of a relative asset path
/// (tileset or unit sprite).  (ABI v3.)  Unit sprite paths are always
/// relative to the read-only game-data root; a tileset `image_path` is
/// relative to whichever root `image_path_root` names (ABI v5).
#define PEONPAD_TABLETOP_MAX_PATH    128u

// ── Fog-of-war cell state ─────────────────────────────────────────────────

/// Visibility state of a single map tile from the local player's perspective.
typedef enum PeonPadFogState {
    PEONPAD_FOG_UNSEEN   = 0, ///< Never explored.
    PEONPAD_FOG_EXPLORED = 1, ///< Seen previously; currently out of sight.
    PEONPAD_FOG_VISIBLE  = 2, ///< Currently within line of sight.
} PeonPadFogState;

// ── Per-tile terrain record ───────────────────────────────────────────────

/// Transport-neutral terrain classification derived from the engine tileset.
/// The UI maps this to its own terrain-kind palette; it never needs to know
/// the tileset-specific graphic index.  (ABI v2.)
typedef enum PeonPadTerrainClass {
    PEONPAD_TERRAIN_UNKNOWN = 0, ///< Unclassified / not yet resolved.
    PEONPAD_TERRAIN_GRASS   = 1, ///< Open, walkable land.
    PEONPAD_TERRAIN_DIRT    = 2, ///< Bare ground / mud / road.
    PEONPAD_TERRAIN_WATER   = 3, ///< Deep water (impassable to land units).
    PEONPAD_TERRAIN_ROCK    = 4, ///< Rock / mountain (blocks movement & sight).
    PEONPAD_TERRAIN_FOREST  = 5, ///< Trees / harvestable wood.
    PEONPAD_TERRAIN_COAST   = 6, ///< Shallow water / shoreline transition.
    PEONPAD_TERRAIN_WALL    = 7, ///< Built or rubble wall.
} PeonPadTerrainClass;

/// One terrain cell in a snapshot, corresponding to a single map tile.
/// Cells are stored in row-major order: cell[y * map_width + x].
typedef struct PeonPadTerrainCell {
    uint16_t tile_index;    ///< Tileset tile number (index into the tileset's tiles).
    uint8_t  fog_state;     ///< PeonPadFogState from the local player's POV.
    uint8_t  terrain_class; ///< PeonPadTerrainClass (ABI v2; was reserved _pad).
    uint16_t graphic_index; ///< Pixel-grid frame index of this tile within the
                            ///< tileset image (ABI v3).  Combined with the
                            ///< snapshot's PeonPadTilesetDescriptor it yields the
                            ///< source rectangle for the real tile art.
    uint8_t  _pad[2];       ///< Must be zero; reserved for future payload (ABI v3).
} PeonPadTerrainCell;

// ── Per-unit record ───────────────────────────────────────────────────────

/// One unit's state as captured in a snapshot.
/// Dead units (alive == 0) are included so the UI can play removal
/// animations before discarding them; they appear at most once with
/// hp == 0 after the tick they died.
typedef struct PeonPadUnitRecord {
    uint32_t id;        ///< Slot ID (UnitNumber). Note: slots are reused after a
                        ///< unit dies and the slot is released, so consumers
                        ///< should key long-lived state on (id, alive) pairs and
                        ///< treat a newly-alive unit at a previously-dead id as
                        ///< a distinct entity.  IDs are unique among concurrent
                        ///< alive units within a session.
    uint8_t  owner;     ///< Player index 0-15.
    uint8_t  alive;     ///< 1 = alive on map; 0 = dead or removed.
    uint8_t  selected;  ///< 1 = in the local player's current selection.
    uint8_t  facing;    ///< 0-255 direction, 0 = North, clockwise (Stratagus).
    int32_t  hp;        ///< Current hit points (≥ 0).
    int32_t  max_hp;    ///< Maximum hit points for this unit type (> 0 when known).
    int16_t  tile_x;    ///< Map tile column.
    int16_t  tile_y;    ///< Map tile row.
    float    world_x;   ///< Sub-tile pixel x offset (for smooth animation).
    float    world_y;   ///< Sub-tile pixel y offset (for smooth animation).
    uint16_t type_id;   ///< Engine unit-type index (ABI v2). Key into the
                        ///< snapshot's unit-type registry; stable within a
                        ///< session.  0 is a valid type id; consumers that
                        ///< need the ident string look it up in the registry.
    uint16_t sprite_frame; ///< Engine-resolved sprite-sheet frame index for this
                        ///< unit's current facing + animation (ABI v3; was the
                        ///< reserved `_pad2`).  Already accounts for the unit's
                        ///< direction using the engine's own draw formula, so
                        ///< the UI never re-derives it.  Index into the sprite
                        ///< sheet described by this unit's PeonPadUnitType.
    uint8_t  sprite_mirror; ///< 1 = draw the sprite horizontally mirrored (ABI
                        ///< v3).  Set for the mirrored half of a flip-storage
                        ///< sprite sheet (e.g. west reusing a flipped east frame).
    uint8_t  _pad3[3];  ///< Must be zero; reserved for future payload (ABI v3).
} PeonPadUnitRecord;

// ── Unit-type registry entry (ABI v2) ─────────────────────────────────────

/// How the UI should present a unit type's art (ABI v4).  Derived from the
/// engine's CUnitType: a type that gives a resource is a RESOURCE (gold mine,
/// oil patch), an otherwise-Building type is a BUILDING, everything else is a
/// MOBILE unit.  Buildings and resources render at their tile footprint and
/// stay map-oriented; mobile units get camera-relative directional sprites.
typedef enum PeonPadRenderCategory {
    PEONPAD_RENDER_MOBILE   = 0, ///< A mobile unit (footman, grunt, peon, ...).
    PEONPAD_RENDER_BUILDING = 1, ///< A building (town hall, farm, barracks, ...).
    PEONPAD_RENDER_RESOURCE = 2, ///< A resource source (gold mine, oil patch).
} PeonPadRenderCategory;

/// Maps a unit record's `type_id` to a stable engine ident string (e.g.
/// "unit-footman", "unit-grunt").  Each snapshot carries the set of types
/// referenced by its units so the UI can resolve real art via
/// TabletopAssetResolver without embedding any proprietary asset.
/// `ident` is always NUL-terminated and never longer than
/// PEONPAD_TABLETOP_MAX_IDENT - 1 characters.
typedef struct PeonPadUnitType {
    uint16_t type_id;                       ///< Matches PeonPadUnitRecord.type_id.
    uint8_t  _pad[2];                       ///< Must be zero.
    char     ident[PEONPAD_TABLETOP_MAX_IDENT]; ///< NUL-terminated engine ident.
    // ── ABI v3 sprite metadata (engine-owned, sourced from CUnitType) ──
    char     sprite_path[PEONPAD_TABLETOP_MAX_PATH]; ///< NUL-terminated sprite
                             ///< sheet path, relative to the game-data root
                             ///< (e.g. "human/units/footman.png").  Empty when
                             ///< the type has no sprite; the UI then falls back
                             ///< to a procedural billboard for that unit.
    uint16_t frame_width;    ///< Sprite frame width in pixels (0 if unknown).
    uint16_t frame_height;   ///< Sprite frame height in pixels (0 if unknown).
    uint8_t  num_directions; ///< Directions stored in the sheet (e.g. 1, 4, 5, 8).
    uint8_t  flip;           ///< 1 = the sheet stores five directions and mirrors
                             ///< the other three (Warcraft II convention).
    uint8_t  team_color_start; ///< First palette index remapped for team color.
    uint8_t  team_color_count; ///< Number of palette entries remapped (0 if none).
    // ── ABI v4 render-category + footprint (engine-owned, from CUnitType) ──
    uint8_t  render_category;  ///< PeonPadRenderCategory (mobile/building/resource).
    uint8_t  tile_width;       ///< Footprint width in map tiles (0 ⇒ treat as 1).
    uint8_t  tile_height;      ///< Footprint height in map tiles (0 ⇒ treat as 1).
    uint8_t  _pad4;            ///< Must be zero; reserved for future payload (ABI v4).
} PeonPadUnitType;

// ── Tileset descriptor (ABI v3; path-root discriminator added in v5) ─────

/// Which root `PeonPadTilesetDescriptor.image_path` is relative to (ABI v5).
/// The engine's expanded-tileset PNG cache (see PeonPadTabletopBridge.cpp's
/// ExportExpandedTilesetPNG) lives under the writable user/cache root, never
/// the read-only staged game-data root — this field lets the UI resolve the
/// path against the correct root explicitly, rather than inferring placement
/// from a filename convention (e.g. a "tabletop-generated/" prefix), which a
/// future rename/relocation of that convention could silently break.
typedef enum PeonPadTilesetPathRoot {
    PEONPAD_TILESET_PATH_ROOT_DATA  = 0, ///< Relative to the read-only staged game-data root (`-d`).
    PEONPAD_TILESET_PATH_ROOT_CACHE = 1, ///< Relative to the writable user/cache root (`-u`).
} PeonPadTilesetPathRoot;

/// Describes the tileset image the snapshot's terrain `graphic_index` values
/// index into.  One descriptor per snapshot (the active map's tileset).  With
/// `graphic_index`, `pixel_tile_width/height`, and `image_width` the UI derives
/// each tile's source rectangle without parsing any tileset Lua.
/// `image_path` is relative to the root named by `image_path_root` (ABI v5;
/// always the game-data root in v3/v4) and NUL-terminated; it is empty for
/// synthetic or terrain-less snapshots.
typedef struct PeonPadTilesetDescriptor {
    char     image_path[PEONPAD_TABLETOP_MAX_PATH]; ///< Relative tileset PNG path.
    uint16_t pixel_tile_width;  ///< Tile width in pixels within the image.
    uint16_t pixel_tile_height; ///< Tile height in pixels within the image.
    uint16_t image_width;       ///< Tileset image width in pixels (0 if unknown).
    uint16_t image_height;      ///< Tileset image height in pixels (0 if unknown).
    char     name[PEONPAD_TABLETOP_MAX_IDENT]; ///< NUL-terminated tileset name.
    // ── ABI v5 path-root discriminator ──────────────────────────────────
    uint8_t  image_path_root;  ///< PeonPadTilesetPathRoot: which root `image_path` is relative to.
    uint8_t  _pad5;            ///< Must be zero; reserved for future payload (ABI v5).
} PeonPadTilesetDescriptor;

// ── Snapshot (opaque, reference-counted) ─────────────────────────────────

/// An immutable, coherent snapshot of game state captured at one simulation
/// tick.  Use the accessor functions below; do not dereference the pointer.
typedef struct PeonPadSnapshot PeonPadSnapshot;

/// ABI version embedded in this snapshot.
/// Always PEONPAD_TABLETOP_ABI_VERSION for snapshots produced by this build.
/// A consumer that sees a different value must discard the snapshot.
uint32_t peonpad_snapshot_abi_version(const PeonPadSnapshot *s);

/// Monotonically-increasing generation counter (== GameCycle at publish time).
/// Zero means the snapshot was produced via peonpad_tabletop_publish_synthetic.
uint64_t peonpad_snapshot_generation(const PeonPadSnapshot *s);

/// Map width in tiles.
uint32_t peonpad_snapshot_map_width(const PeonPadSnapshot *s);

/// Map height in tiles.
uint32_t peonpad_snapshot_map_height(const PeonPadSnapshot *s);

/// Number of terrain cells (== map_width × map_height).
/// May be zero for a synthetic snapshot with no terrain.
uint32_t peonpad_snapshot_terrain_count(const PeonPadSnapshot *s);

/// Pointer to the terrain cell array (row-major, map_width × map_height).
/// Valid until peonpad_snapshot_release() drops the last reference.
/// Returns NULL when terrain_count == 0.
const PeonPadTerrainCell *peonpad_snapshot_terrain(const PeonPadSnapshot *s);

/// Number of unit records in this snapshot (≤ PEONPAD_TABLETOP_MAX_UNITS).
uint32_t peonpad_snapshot_unit_count(const PeonPadSnapshot *s);

/// Pointer to the unit record array.
/// Valid until peonpad_snapshot_release() drops the last reference.
/// Returns NULL when unit_count == 0.
const PeonPadUnitRecord *peonpad_snapshot_units(const PeonPadSnapshot *s);

/// Number of entries in this snapshot's unit-type registry (ABI v2).
/// May be zero for a synthetic or terrain-only snapshot.
uint32_t peonpad_snapshot_unit_type_count(const PeonPadSnapshot *s);

/// Pointer to the unit-type registry array (ABI v2).
/// Each entry maps a `type_id` to a stable engine ident string.
/// Valid until peonpad_snapshot_release() drops the last reference.
/// Returns NULL when unit_type_count == 0.
const PeonPadUnitType *peonpad_snapshot_unit_types(const PeonPadSnapshot *s);

/// Pointer to this snapshot's tileset descriptor (ABI v3), or NULL when the
/// snapshot carries no tileset (synthetic or terrain-less snapshots).
/// Valid until peonpad_snapshot_release() drops the last reference.
const PeonPadTilesetDescriptor *peonpad_snapshot_tileset(const PeonPadSnapshot *s);

/// Increment the reference count.  Returns 0 on success, -1 if s is NULL.
int peonpad_snapshot_retain(PeonPadSnapshot *s);

/// Decrement the reference count; frees the snapshot when it reaches zero.
/// Safe to call with NULL (no-op).
void peonpad_snapshot_release(PeonPadSnapshot *s);

// ── Command intake ─────────────────────────────────────────────────────────

/// Commands understood by the bridge's intake queue.
typedef enum PeonPadCommandType {
    PEONPAD_CMD_NONE         = 0, ///< Sentinel / unused.
    PEONPAD_CMD_SELECT       = 1, ///< Add unit_id to the local selection.
    PEONPAD_CMD_DESELECT     = 2, ///< Remove unit_id from the local selection.
    PEONPAD_CMD_MOVE         = 3, ///< Move unit(s) to (tile_x, tile_y).
                                  ///<   unit_id != 0: select just that unit first,
                                  ///<                 then issue the move order.
                                  ///<   unit_id == 0: move all currently-selected units.
    PEONPAD_CMD_STOP         = 4, ///< Order unit_id to stop its current action.
    PEONPAD_CMD_DESELECT_ALL = 5, ///< Clear the entire selection (unit_id ignored).
} PeonPadCommandType;

/// A single command posted from the UI thread to the simulation thread.
/// Fields not used by a given command type must be zero.
typedef struct PeonPadCommand {
    uint32_t type;          ///< PeonPadCommandType.
    uint32_t abi_ver;       ///< Must equal PEONPAD_TABLETOP_ABI_VERSION.
    uint32_t unit_id;       ///< Target unit (SELECT / DESELECT / STOP).
                            ///< For MOVE: if non-zero, select this unit then move.
    int32_t  tile_x;        ///< Target tile column (MOVE only).
    int32_t  tile_y;        ///< Target tile row (MOVE only).
    uint8_t  _reserved[8];  ///< Must be zero; reserved for future payload.
} PeonPadCommand;

// ── Bridge lifecycle ───────────────────────────────────────────────────────

/// Initialize the bridge.  Must be called once from the simulation thread
/// before any other bridge function.
/// Returns 0 on success, -1 if already initialized.
int peonpad_tabletop_init(void);

/// Tear down the bridge: drops the latest snapshot (if any) and flushes the
/// command queue.  Safe to call if peonpad_tabletop_init was never called.
/// Call from the simulation thread during engine shutdown.
void peonpad_tabletop_cleanup(void);

/// Called by the simulation thread after each game tick to capture and publish
/// a new coherent snapshot of the current game state.
/// No-ops if the bridge is not initialized or no map is loaded.
/// When built without PEONPAD_TABLETOP this is a compiled-out no-op.
void peonpad_tabletop_publish_snapshot(void);

/// Called by the simulation thread before each game tick to apply queued UI
/// commands (select/deselect/move/stop) to the game state.
/// No-ops if the bridge is not initialized.
void peonpad_tabletop_drain_commands(void);

/// Returns a retained snapshot of the most recently published state, or NULL
/// if no snapshot has been published yet.
/// The caller must call peonpad_snapshot_release() when done.
/// Thread-safe; callable from any thread.
PeonPadSnapshot *peonpad_tabletop_latest_snapshot(void);

/// Post a command to be processed by the simulation thread on its next tick.
/// Thread-safe; callable from any thread (the UI thread in practice).
///
/// Returns:
///   0   success
///  -1   bridge not initialized
///  -2   NULL or malformed command (wrong abi_ver, out-of-range tile,
///       unknown command type)
///  -3   command queue is full (PEONPAD_TABLETOP_MAX_COMMANDS)
int peonpad_tabletop_post_command(const PeonPadCommand *cmd);

/// Synthetic publish (always available, does not require a running engine).
/// Creates a snapshot from explicit caller-supplied arrays and makes it the
/// latest snapshot.  Intended for unit tests and tool use; must not be called
/// from within the game loop when peonpad_tabletop_publish_snapshot is active.
///
/// terrain may be NULL when terrain_count == 0.
/// units   may be NULL when unit_count == 0.
///
/// Returns 0 on success, -1 if the bridge is not initialized, -2 if counts
/// exceed the hard limits or are inconsistent with map_width × map_height.
int peonpad_tabletop_publish_synthetic(
    uint64_t                    generation,
    uint32_t                    map_width,
    uint32_t                    map_height,
    const PeonPadTerrainCell   *terrain,
    uint32_t                    terrain_count,
    const PeonPadUnitRecord    *units,
    uint32_t                    unit_count
);

/// Synthetic publish including the unit-type registry (ABI v2).
/// Behaves exactly like peonpad_tabletop_publish_synthetic but also attaches
/// a unit-type registry so consumers can resolve `type_id` → ident.
///
/// types may be NULL when type_count == 0.  Returns 0 on success, -1 if the
/// bridge is not initialized, -2 if any count exceeds the hard limits, is
/// inconsistent with map_width × map_height, or a type ident is not
/// NUL-terminated within PEONPAD_TABLETOP_MAX_IDENT bytes.
int peonpad_tabletop_publish_synthetic_v2(
    uint64_t                    generation,
    uint32_t                    map_width,
    uint32_t                    map_height,
    const PeonPadTerrainCell   *terrain,
    uint32_t                    terrain_count,
    const PeonPadUnitRecord    *units,
    uint32_t                    unit_count,
    const PeonPadUnitType      *types,
    uint32_t                    type_count
);

/// Synthetic publish including the ABI v3 tileset descriptor.
/// Behaves exactly like peonpad_tabletop_publish_synthetic_v2 but also attaches
/// a single tileset descriptor so consumers can map terrain `graphic_index`
/// values to source rectangles.  `tileset` may be NULL (no tileset attached).
///
/// Returns 0 on success, -1 if the bridge is not initialized, -2 if any count
/// exceeds the hard limits, is inconsistent with map_width × map_height, a type
/// ident/sprite_path is not NUL-terminated within its fixed buffer, or the
/// tileset image_path/name is not NUL-terminated within its fixed buffer.
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
    const PeonPadTilesetDescriptor *tileset
);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // PEONPAD_TABLETOP_BRIDGE_H
