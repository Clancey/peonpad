// TabletopGameplayState.swift
//
// Versioned, Codable pure-state gameplay snapshot for the visionOS tabletop
// slice: map tiles, terrain, fog-of-war, unit roster (identity, owner, HP,
// facing, board position), selection, and deterministic command reduction
// (select, move, stop, deselectAll).
//
// Nothing in this file imports SwiftUI, RealityKit, or UIKit. It depends
// only on TabletopGestureState.swift (for WarcraftFacing), which is compiled
// in the same module. Like the gesture-state layer, it is unit-tested on the
// host Mac without booting the visionOS Simulator:
//
//   ./scripts/test-visionos-tabletop-gameplay.sh
import Foundation

// MARK: - Map geometry

/// The dimensions of the playfield in tile units.
public struct TabletopMapSize: Codable, Equatable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

// MARK: - Terrain

/// The kind of terrain occupying a map tile.
public enum TabletopTerrainKind: String, Codable, Equatable, CaseIterable {
    case grass
    case dirt
    case water
    case rock
    case forest
}

/// The terrain assignment for one board tile.
public struct TabletopTerrainTile: Codable, Equatable {
    public var tileX: Int
    public var tileZ: Int
    public var kind: TabletopTerrainKind
    /// Pixel-grid frame index of this tile within the tileset image (from the
    /// engine snapshot, ABI v3). `nil` for procedural/demo content. The render
    /// layer combines this with the snapshot's `assets.tileset` to crop the
    /// real tile art, falling back to a solid color when either is missing.
    public var graphicIndex: Int?
    public init(tileX: Int, tileZ: Int, kind: TabletopTerrainKind,
                graphicIndex: Int? = nil) {
        self.tileX = tileX
        self.tileZ = tileZ
        self.kind = kind
        self.graphicIndex = graphicIndex
    }
}

/// The three canonical fog-of-war states for one board tile, mirroring the
/// engine's `EngineFogState` / `PeonPadFogState` (ABI). Ordered by increasing
/// knowledge so `>=` comparisons read naturally.
public enum TabletopFogVisibility: UInt8, Codable, Equatable, CaseIterable {
    /// Never explored — rendered as an opaque dark shroud.
    case unexplored = 0
    /// Explored previously but not currently in sight — rendered dim/translucent.
    case explored = 1
    /// Currently within line of sight — rendered clear (no veil).
    case visible = 2
}

/// The fog-of-war state for one board tile. Carries the full three-state
/// `visibility`; `isRevealed` remains as a binary convenience (explored OR
/// visible) so existing binary callers and tests keep working.
public struct TabletopFogTile: Codable, Equatable {
    public var tileX: Int
    public var tileZ: Int
    /// Canonical three-state visibility from the local player's POV.
    public var visibility: TabletopFogVisibility

    /// Binary reveal state: `true` when the tile is explored or visible. Setting
    /// it is lossy (maps to `.visible`/`.unexplored`); prefer `visibility`.
    public var isRevealed: Bool {
        get { visibility != .unexplored }
        set { visibility = newValue ? .visible : .unexplored }
    }

    public init(tileX: Int, tileZ: Int, visibility: TabletopFogVisibility) {
        self.tileX = tileX
        self.tileZ = tileZ
        self.visibility = visibility
    }

    /// Backward-compatible binary initializer: `isRevealed` maps to `.visible`,
    /// otherwise `.unexplored`.
    public init(tileX: Int, tileZ: Int, isRevealed: Bool) {
        self.init(tileX: tileX, tileZ: tileZ,
                  visibility: isRevealed ? .visible : .unexplored)
    }
}

// MARK: - Unit

/// One unit's complete pure state. `id` is stable across commands. `hp == 0`
/// means the unit is dead; commands on dead units are rejected.
public struct TabletopGameplayUnit: Codable, Equatable {
    public var id: String
    /// Player/team index (0-based). Used for tint mapping in the render layer.
    public var owner: Int
    public var hp: Int
    public var maxHP: Int
    /// Board-space facing (radians). 0 = board north (+Z), increasing
    /// clockwise, following the `WarcraftFacing` convention.
    public var facingRadians: Double
    public var tileX: Int
    public var tileZ: Int
    /// Engine unit-type identifier (e.g. `"unit-footman"`), used by the render
    /// layer to resolve real Wargus sprites via `TabletopAssetResolver`. Empty
    /// for procedural/demo content that has no engine-defined type.
    public var kind: String
    /// Engine-resolved sprite-sheet frame index for this unit's current facing
    /// + animation (from the snapshot, ABI v3). `nil` for procedural content.
    public var spriteFrame: Int?
    /// Whether the resolved sprite frame must be drawn horizontally mirrored
    /// (ABI v3). `nil`/`false` for procedural content.
    public var spriteMirror: Bool?

    public init(
        id: String,
        owner: Int,
        hp: Int,
        maxHP: Int,
        facingRadians: Double,
        tileX: Int,
        tileZ: Int,
        kind: String = "",
        spriteFrame: Int? = nil,
        spriteMirror: Bool? = nil
    ) {
        self.id = id
        self.owner = owner
        self.hp = hp
        self.maxHP = maxHP
        self.facingRadians = facingRadians
        self.tileX = tileX
        self.tileZ = tileZ
        self.kind = kind
        self.spriteFrame = spriteFrame
        self.spriteMirror = spriteMirror
    }

    /// A unit with `hp == 0` is dead. Commands (select, move, stop) that
    /// target a dead unit are rejected by the command reducer.
    public var isAlive: Bool { hp > 0 }
}

// MARK: - Selection

/// Which unit the right-hand command gesture has highlighted. `nil` means
/// nothing is selected. The `validatedSelectedUnit` computed property on the
/// snapshot never returns a dead unit even if `selectedUnitID` still names
/// one, so rendering and command dispatch can safely use it.
public struct TabletopGameplaySelection: Codable, Equatable {
    public var selectedUnitID: String?
    public init(selectedUnitID: String? = nil) {
        self.selectedUnitID = selectedUnitID
    }
}

// MARK: - Asset catalog (engine-owned art descriptors, ABI v3)

/// The active map's tileset image descriptor, carried on the snapshot so the
/// render layer can crop real tile art without parsing any tileset script.
public struct TabletopTilesetInfo: Codable, Equatable, Sendable {
    /// Tileset image path relative to the game-data root.
    public var imagePath: String
    public var pixelTileWidth: Int
    public var pixelTileHeight: Int
    /// Tileset image dimensions in pixels; `0` when the engine did not report
    /// them (the render layer then derives columns from the decoded image).
    public var imageWidth: Int
    public var imageHeight: Int
    public var name: String
    public init(
        imagePath: String, pixelTileWidth: Int, pixelTileHeight: Int,
        imageWidth: Int = 0, imageHeight: Int = 0, name: String = ""
    ) {
        self.imagePath = imagePath
        self.pixelTileWidth = pixelTileWidth
        self.pixelTileHeight = pixelTileHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.name = name
    }
}

/// One unit type's sprite-sheet descriptor, carried on the snapshot so the
/// How the render layer presents a unit type (mirrors `EngineRenderCategory`,
/// ABI v4). Buildings/resources render at their tile footprint and stay
/// map-oriented; mobile units get camera-relative directional sprites.
public enum TabletopRenderCategory: String, Codable, Equatable {
    case mobile
    case building
    case resource

    /// Whether a unit of this category billboards toward the viewer and gets
    /// camera-relative directional sprites. Only mobile units do; buildings and
    /// resources stay map-oriented (fixed board orientation) so they do not spin
    /// as the board is orbited.
    public var billboardsTowardViewer: Bool { self == .mobile }
}

/// render layer can locate and tint real sprites keyed by engine ident.
public struct TabletopUnitSpriteInfo: Codable, Equatable {
    /// Sprite-sheet path relative to the game-data root.
    public var spritePath: String
    public var frameWidth: Int
    public var frameHeight: Int
    /// Directions stored in the sheet (e.g. 1, 4, 5, 8).
    public var numDirections: Int
    /// Whether the sheet stores five directions and mirrors the other three.
    public var flip: Bool
    /// Palette span remapped for team color (`teamColorCount == 0` = none).
    public var teamColorStart: Int
    public var teamColorCount: Int
    /// Render category (ABI v4): mobile / building / resource.
    public var renderCategory: TabletopRenderCategory
    /// Tile footprint in map tiles (ABI v4); at least 1×1.
    public var footprintWidth: Int
    public var footprintHeight: Int
    public init(
        spritePath: String, frameWidth: Int, frameHeight: Int,
        numDirections: Int, flip: Bool,
        teamColorStart: Int = 0, teamColorCount: Int = 0,
        renderCategory: TabletopRenderCategory = .mobile,
        footprintWidth: Int = 1, footprintHeight: Int = 1
    ) {
        self.spritePath = spritePath
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.numDirections = numDirections
        self.flip = flip
        self.teamColorStart = teamColorStart
        self.teamColorCount = teamColorCount
        self.renderCategory = renderCategory
        self.footprintWidth = max(1, footprintWidth)
        self.footprintHeight = max(1, footprintHeight)
    }
}

/// The engine-owned art descriptors for a snapshot: the map tileset plus a
/// per-unit-type sprite descriptor keyed by engine ident (e.g.
/// `"unit-footman"`). Absent (`nil`) for procedural/demo snapshots and for
/// pre-v3 engines, so the render layer falls back to procedural content.
public struct TabletopAssetCatalog: Codable, Equatable {
    public var tileset: TabletopTilesetInfo?
    public var unitTypes: [String: TabletopUnitSpriteInfo]
    public init(
        tileset: TabletopTilesetInfo? = nil,
        unitTypes: [String: TabletopUnitSpriteInfo] = [:]
    ) {
        self.tileset = tileset
        self.unitTypes = unitTypes
    }

    /// The sprite descriptor for a unit ident, or `nil` when the catalog has
    /// no entry (missing sprite → procedural billboard fallback for that unit).
    public func sprite(forUnitKind kind: String) -> TabletopUnitSpriteInfo? {
        unitTypes[kind]
    }
}

// MARK: - Versioned snapshot

/// The complete, serialisable gameplay state. All fields are value types;
/// commands produce a new snapshot via `TabletopGameplayCommandReducer.reduce`.
public struct TabletopGameplaySnapshot: Codable, Equatable {
    /// Bumped when the serialised layout changes incompatibly.
    public static let currentVersion = 1

    public var version: Int
    public var mapSize: TabletopMapSize
    /// Per-tile terrain. Query via `terrain(atTileX:tileZ:)`.
    public var terrain: [TabletopTerrainTile]
    /// Per-tile fog-of-war state. Query via `fog(atTileX:tileZ:)`.
    public var fogMask: [TabletopFogTile]
    public var units: [TabletopGameplayUnit]
    public var selection: TabletopGameplaySelection
    /// Engine-owned art descriptors (tileset + per-unit sprite sheets, ABI v3).
    /// `nil` for procedural/demo snapshots; the render layer then uses
    /// procedural terrain colors and billboards.
    public var assets: TabletopAssetCatalog?

    public init(
        version: Int,
        mapSize: TabletopMapSize,
        terrain: [TabletopTerrainTile],
        fogMask: [TabletopFogTile],
        units: [TabletopGameplayUnit],
        selection: TabletopGameplaySelection,
        assets: TabletopAssetCatalog? = nil
    ) {
        self.version = version
        self.mapSize = mapSize
        self.terrain = terrain
        self.fogMask = fogMask
        self.units = units
        self.selection = selection
        self.assets = assets
    }

    // MARK: Convenience accessors

    /// Terrain at the given tile, or `.grass` if the tile is off the map.
    public func terrain(atTileX x: Int, tileZ z: Int) -> TabletopTerrainKind {
        terrain.first(where: { $0.tileX == x && $0.tileZ == z })?.kind ?? .grass
    }

    /// Fog state at the given tile. Off-map tiles are treated as unrevealed.
    public func fog(atTileX x: Int, tileZ z: Int) -> Bool {
        fogMask.first(where: { $0.tileX == x && $0.tileZ == z })?.isRevealed ?? false
    }

    /// Canonical three-state fog visibility at the given tile. Off-map tiles are
    /// treated as `.unexplored`.
    public func fogVisibility(atTileX x: Int, tileZ z: Int) -> TabletopFogVisibility {
        fogMask.first(where: { $0.tileX == x && $0.tileZ == z })?.visibility ?? .unexplored
    }

    /// The currently selected unit, but only if it is alive (HP > 0). Dead
    /// units that were selected before they were killed are never returned
    /// here, so downstream consumers never need to guard for that case.
    public var validatedSelectedUnit: TabletopGameplayUnit? {
        guard let id = selection.selectedUnitID else { return nil }
        return units.first(where: { $0.id == id && $0.isAlive })
    }
}

// MARK: - Commands

/// The set of gameplay commands the right-hand command reducer can issue.
/// All commands are value types and are `Codable` so they can be serialised
/// for replays or deterministic tests.
public enum TabletopGameplayCommand: Equatable, Codable {
    case selectUnit(id: String)
    case deselectAll
    /// Move a unit to a different tile by board-coordinate. The reducer
    /// validates that the unit is alive before applying.
    case moveUnit(id: String, toTileX: Int, toTileZ: Int)
    /// Stop any pending movement for a unit. In the pure state model, this
    /// is a no-op beyond validation (there is no velocity to clear), but it
    /// exists so higher-level state machines can emit it and receive a
    /// validation result without special-casing.
    case stopUnit(id: String)
}

// MARK: - Validation

/// The outcome of validating a command against a snapshot before applying it.
public enum TabletopCommandValidation: Equatable {
    case valid
    case rejectedUnitNotFound(id: String)
    /// The targeted unit exists but has `hp == 0` and cannot receive commands.
    case rejectedDeadUnit(id: String, hp: Int)
}

// MARK: - Command reducer

/// Applies commands deterministically against a snapshot value. The same
/// (snapshot, command) pair always produces the same result, so these
/// functions are safe to call from tests without any framework setup.
public enum TabletopGameplayCommandReducer {
    /// Validates a command against a snapshot. Returns `.valid` if the
    /// command can safely be applied, or a rejection reason if it cannot.
    public static func validate(
        _ snapshot: TabletopGameplaySnapshot,
        command: TabletopGameplayCommand
    ) -> TabletopCommandValidation {
        switch command {
        case .deselectAll:
            return .valid
        case .selectUnit(let id):
            return validateUnit(id, in: snapshot)
        case .moveUnit(let id, _, _):
            return validateUnit(id, in: snapshot)
        case .stopUnit(let id):
            return validateUnit(id, in: snapshot)
        }
    }

    /// Applies a command to a snapshot, returning the updated state. When
    /// the command is invalid (dead unit, unit not found), the snapshot is
    /// returned unchanged rather than trapping.
    public static func reduce(
        _ snapshot: TabletopGameplaySnapshot,
        command: TabletopGameplayCommand
    ) -> TabletopGameplaySnapshot {
        guard validate(snapshot, command: command) == .valid else {
            return snapshot
        }
        var next = snapshot
        switch command {
        case .deselectAll:
            next.selection = TabletopGameplaySelection()
        case .selectUnit(let id):
            next.selection = TabletopGameplaySelection(selectedUnitID: id)
        case .moveUnit(let id, let toTileX, let toTileZ):
            if let idx = next.units.firstIndex(where: { $0.id == id }) {
                next.units[idx].tileX = toTileX
                next.units[idx].tileZ = toTileZ
            }
        case .stopUnit:
            // Pure-state model: no velocity to clear. Validation above
            // ensures the unit exists and is alive; nothing else to update.
            break
        }
        return next
    }

    // MARK: Private helpers

    private static func validateUnit(
        _ id: String,
        in snapshot: TabletopGameplaySnapshot
    ) -> TabletopCommandValidation {
        guard let unit = snapshot.units.first(where: { $0.id == id }) else {
            return .rejectedUnitNotFound(id: id)
        }
        guard unit.isAlive else {
            return .rejectedDeadUnit(id: id, hp: unit.hp)
        }
        return .valid
    }
}

// MARK: - Demo state

extension TabletopGameplaySnapshot {
    /// A representative procedural demo battlefield: a simple terrain grid,
    /// all tiles initially revealed, and one alive test unit per canonical
    /// Warcraft II facing direction across two player teams. No proprietary
    /// Warcraft II art or data is used -- this is placeholder content to
    /// exercise the spatial board and gameplay mechanics.
    public static func demo() -> TabletopGameplaySnapshot {
        let half = 3  // radius; board is (2*half+1) x (2*half+1) tiles
        let mapSize = TabletopMapSize(width: 2 * half + 1, height: 2 * half + 1)

        // Terrain: mostly grass with procedural patches of other kinds.
        var terrain: [TabletopTerrainTile] = []
        for z in -half...half {
            for x in -half...half {
                let kind: TabletopTerrainKind
                if x == -2 && z == 0 { kind = .water }
                else if x == 2 && z == -2 { kind = .rock }
                else if x == 0 && z == 3 { kind = .forest }
                else if (x + z).isMultiple(of: 4) { kind = .dirt }
                else { kind = .grass }
                terrain.append(TabletopTerrainTile(tileX: x, tileZ: z, kind: kind))
            }
        }

        // Fog: all tiles revealed in the demo.
        var fogMask: [TabletopFogTile] = []
        for z in -half...half {
            for x in -half...half {
                fogMask.append(TabletopFogTile(tileX: x, tileZ: z, isRevealed: true))
            }
        }

        // Units: one per canonical Warcraft II facing direction, two teams.
        let units: [TabletopGameplayUnit] = [
            TabletopGameplayUnit(id: "sentry.north",     owner: 0, hp: 10, maxHP: 10,
                facingRadians: WarcraftFacing.north.radians,     tileX:  0, tileZ: -2),
            TabletopGameplayUnit(id: "sentry.northeast", owner: 0, hp: 10, maxHP: 10,
                facingRadians: WarcraftFacing.northEast.radians, tileX:  2, tileZ: -1),
            TabletopGameplayUnit(id: "sentry.east",      owner: 0, hp: 10, maxHP: 10,
                facingRadians: WarcraftFacing.east.radians,      tileX:  2, tileZ:  1),
            TabletopGameplayUnit(id: "sentry.southeast", owner: 0, hp: 10, maxHP: 10,
                facingRadians: WarcraftFacing.southEast.radians, tileX:  1, tileZ:  2),
            TabletopGameplayUnit(id: "sentry.south",     owner: 1, hp:  8, maxHP: 10,
                facingRadians: WarcraftFacing.south.radians,     tileX: -1, tileZ:  2),
            TabletopGameplayUnit(id: "sentry.southwest", owner: 1, hp:  8, maxHP: 10,
                facingRadians: WarcraftFacing.southWest.radians, tileX: -2, tileZ:  1),
            TabletopGameplayUnit(id: "sentry.west",      owner: 1, hp:  5, maxHP: 10,
                facingRadians: WarcraftFacing.west.radians,      tileX: -2, tileZ: -1),
            TabletopGameplayUnit(id: "sentry.northwest", owner: 1, hp:  3, maxHP: 10,
                facingRadians: WarcraftFacing.northWest.radians, tileX: -1, tileZ: -2),
        ]

        return TabletopGameplaySnapshot(
            version: currentVersion,
            mapSize: mapSize,
            terrain: terrain,
            fogMask: fogMask,
            units: units,
            selection: TabletopGameplaySelection()
        )
    }
}
