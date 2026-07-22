// EngineTabletopModel.swift
//
// Pure-Swift value types that mirror the engine-side C ABI snapshot
// (PeonPadTabletopBridge.h).  A thin C-reading shim in
// EngineTabletopTransport populates these from a retained `PeonPadSnapshot`;
// everything downstream (the snapshot converter, command encoder, tests)
// operates on these framework-free value types so the conversion logic is
// unit-testable on the host Mac without importing C, SDL, RealityKit, or the
// engine.
//
// Nothing in this file imports SwiftUI, RealityKit, UIKit, or C interop.
import Foundation

/// The ABI version this Swift layer is built against. Must match
/// `PEONPAD_TABLETOP_ABI_VERSION` in PeonPadTabletopBridge.h. The transport
/// rejects any engine snapshot whose embedded version differs, rather than
/// misreading struct fields at a stale layout.
public let kPeonPadTabletopABIVersion: UInt32 = 2

/// Fog-of-war state of a single tile (mirrors `PeonPadFogState`).
public enum EngineFogState: UInt8, Equatable {
    case unseen = 0
    case explored = 1
    case visible = 2
}

/// Transport-neutral terrain classification (mirrors `PeonPadTerrainClass`).
public enum EngineTerrainClass: UInt8, Equatable {
    case unknown = 0
    case grass = 1
    case dirt = 2
    case water = 3
    case rock = 4
    case forest = 5
    case coast = 6
    case wall = 7
}

/// One terrain cell (mirrors `PeonPadTerrainCell`). Stored row-major:
/// cell[y * mapWidth + x].
public struct EngineTerrainCell: Equatable {
    public var tileIndex: UInt16
    public var fogState: UInt8
    public var terrainClass: UInt8
    public init(tileIndex: UInt16, fogState: UInt8, terrainClass: UInt8) {
        self.tileIndex = tileIndex
        self.fogState = fogState
        self.terrainClass = terrainClass
    }
}

/// One unit record (mirrors `PeonPadUnitRecord`, ABI v2).
public struct EngineUnitRecord: Equatable {
    public var id: UInt32
    public var owner: UInt8
    public var alive: UInt8
    public var selected: UInt8
    public var facing: UInt8
    public var hp: Int32
    public var maxHP: Int32
    public var tileX: Int16
    public var tileY: Int16
    public var worldX: Float
    public var worldY: Float
    public var typeID: UInt16

    public init(
        id: UInt32, owner: UInt8, alive: UInt8, selected: UInt8, facing: UInt8,
        hp: Int32, maxHP: Int32, tileX: Int16, tileY: Int16,
        worldX: Float, worldY: Float, typeID: UInt16
    ) {
        self.id = id
        self.owner = owner
        self.alive = alive
        self.selected = selected
        self.facing = facing
        self.hp = hp
        self.maxHP = maxHP
        self.tileX = tileX
        self.tileY = tileY
        self.worldX = worldX
        self.worldY = worldY
        self.typeID = typeID
    }
}

/// One unit-type registry entry (mirrors `PeonPadUnitType`, ABI v2).
public struct EngineUnitType: Equatable {
    public var typeID: UInt16
    public var ident: String
    public init(typeID: UInt16, ident: String) {
        self.typeID = typeID
        self.ident = ident
    }
}

/// A coherent engine snapshot, in framework-free Swift form.
public struct EngineSnapshot: Equatable {
    public var abiVersion: UInt32
    public var generation: UInt64
    public var mapWidth: UInt32
    public var mapHeight: UInt32
    public var terrain: [EngineTerrainCell]
    public var units: [EngineUnitRecord]
    public var unitTypes: [EngineUnitType]

    public init(
        abiVersion: UInt32,
        generation: UInt64,
        mapWidth: UInt32,
        mapHeight: UInt32,
        terrain: [EngineTerrainCell],
        units: [EngineUnitRecord],
        unitTypes: [EngineUnitType]
    ) {
        self.abiVersion = abiVersion
        self.generation = generation
        self.mapWidth = mapWidth
        self.mapHeight = mapHeight
        self.terrain = terrain
        self.units = units
        self.unitTypes = unitTypes
    }
}

/// A UI intent lowered to the engine command ABI shape (mirrors
/// `PeonPadCommand` semantics). Produced by `EngineCommandEncoder`.
public struct EngineCommand: Equatable {
    /// Mirrors `PeonPadCommandType`.
    public enum Kind: UInt32, Equatable {
        case none = 0
        case select = 1
        case deselect = 2
        case move = 3
        case stop = 4
        case deselectAll = 5
    }

    public var kind: Kind
    public var unitID: UInt32
    public var tileX: Int32
    public var tileY: Int32

    public init(kind: Kind, unitID: UInt32 = 0, tileX: Int32 = 0, tileY: Int32 = 0) {
        self.kind = kind
        self.unitID = unitID
        self.tileX = tileX
        self.tileY = tileY
    }
}
