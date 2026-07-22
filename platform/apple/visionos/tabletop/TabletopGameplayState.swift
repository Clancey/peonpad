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
    public init(tileX: Int, tileZ: Int, kind: TabletopTerrainKind) {
        self.tileX = tileX
        self.tileZ = tileZ
        self.kind = kind
    }
}

/// The fog-of-war state for one board tile. `isRevealed` is true when a unit
/// with the local player's team has explored that tile.
public struct TabletopFogTile: Codable, Equatable {
    public var tileX: Int
    public var tileZ: Int
    public var isRevealed: Bool
    public init(tileX: Int, tileZ: Int, isRevealed: Bool) {
        self.tileX = tileX
        self.tileZ = tileZ
        self.isRevealed = isRevealed
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

    public init(
        id: String,
        owner: Int,
        hp: Int,
        maxHP: Int,
        facingRadians: Double,
        tileX: Int,
        tileZ: Int,
        kind: String = ""
    ) {
        self.id = id
        self.owner = owner
        self.hp = hp
        self.maxHP = maxHP
        self.facingRadians = facingRadians
        self.tileX = tileX
        self.tileZ = tileZ
        self.kind = kind
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

    public init(
        version: Int,
        mapSize: TabletopMapSize,
        terrain: [TabletopTerrainTile],
        fogMask: [TabletopFogTile],
        units: [TabletopGameplayUnit],
        selection: TabletopGameplaySelection
    ) {
        self.version = version
        self.mapSize = mapSize
        self.terrain = terrain
        self.fogMask = fogMask
        self.units = units
        self.selection = selection
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
