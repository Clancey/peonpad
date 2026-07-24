// TabletopSnapshotConverter.swift
//
// Pure, deterministic conversion between the engine-side `EngineSnapshot`
// (mirroring the C ABI) and the UI-side `TabletopGameplaySnapshot`, plus the
// inverse lowering of `TabletopGameplayCommand` to `EngineCommand`.
//
// All logic here is framework-free and unit-tested on the host Mac without the
// engine, C interop, or RealityKit. The thin C-reading/-writing shims live in
// EngineTabletopTransport; this file never touches a raw pointer.
import Foundation

// MARK: - Conversion errors

/// Why a raw engine snapshot could not be converted. Surfaced explicitly so
/// the transport can log/skip a bad snapshot rather than silently rendering
/// garbage.
public enum TabletopConversionError: Error, Equatable {
    /// The snapshot's embedded ABI version does not match the version this
    /// build was compiled against. Field offsets cannot be trusted.
    case abiVersionMismatch(expected: UInt32, actual: UInt32)
    /// terrain.count != mapWidth * mapHeight — the snapshot is internally
    /// inconsistent and cannot be laid out on the board.
    case terrainCountMismatch(expected: Int, actual: Int)
    /// mapWidth or mapHeight is zero: there is no board to render.
    case emptyMap
}

// MARK: - Converter

public enum TabletopSnapshotConverter {

    /// Converts an engine snapshot to a UI gameplay snapshot.
    ///
    /// - Throws: `TabletopConversionError` when the snapshot is unusable
    ///   (ABI mismatch, inconsistent terrain count, or empty map).
    public static func convert(
        _ engine: EngineSnapshot,
        expectedABIVersion: UInt32 = kPeonPadTabletopABIVersion
    ) throws -> TabletopGameplaySnapshot {
        guard engine.abiVersion == expectedABIVersion else {
            throw TabletopConversionError.abiVersionMismatch(
                expected: expectedABIVersion, actual: engine.abiVersion)
        }
        let width = Int(engine.mapWidth)
        let height = Int(engine.mapHeight)
        guard width > 0, height > 0 else {
            throw TabletopConversionError.emptyMap
        }
        guard engine.terrain.count == width * height else {
            throw TabletopConversionError.terrainCountMismatch(
                expected: width * height, actual: engine.terrain.count)
        }

        // Terrain + fog (row-major: cell[y * width + x]).
        var terrain: [TabletopTerrainTile] = []
        var fog: [TabletopFogTile] = []
        terrain.reserveCapacity(width * height)
        fog.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let cell = engine.terrain[y * width + x]
                terrain.append(TabletopTerrainTile(
                    tileX: x, tileZ: y, kind: terrainKind(cell.terrainClass),
                    tileIndex: Int(cell.tileIndex),
                    graphicIndex: Int(cell.graphicIndex)))
                fog.append(TabletopFogTile(
                    tileX: x, tileZ: y, visibility: fogVisibility(cell.fogState)))
            }
        }

        // Unit-type registry: type_id → ident, plus the ABI v3 sprite catalog
        // keyed by ident so the render layer can resolve real art.
        var identByType: [UInt16: String] = [:]
        identByType.reserveCapacity(engine.unitTypes.count)
        var spriteByIdent: [String: TabletopUnitSpriteInfo] = [:]
        spriteByIdent.reserveCapacity(engine.unitTypes.count)
        for t in engine.unitTypes {
            identByType[t.typeID] = t.ident
            if !t.spritePath.isEmpty {
                spriteByIdent[t.ident] = TabletopUnitSpriteInfo(
                    spritePath: t.spritePath,
                    frameWidth: Int(t.frameWidth),
                    frameHeight: Int(t.frameHeight),
                    numDirections: Int(t.numDirections),
                    flip: t.flip != 0,
                    teamColorStart: Int(t.teamColorStart),
                    teamColorCount: Int(t.teamColorCount),
                    renderCategory: renderCategory(t.renderCategory),
                    footprintWidth: Int(t.tileWidth),
                    footprintHeight: Int(t.tileHeight))
            }
        }

        // Units. The C selection is per-unit (`selected`); the UI selection is
        // single. Choose the first selected unit as the UI's selected unit so
        // the highlight and command dispatch remain coherent.
        var units: [TabletopGameplayUnit] = []
        units.reserveCapacity(engine.units.count)
        var selectedID: String?
        for u in engine.units {
            let id = String(u.id)
            units.append(TabletopGameplayUnit(
                id: id,
                owner: Int(u.owner),
                hp: Int(u.hp),
                maxHP: Int(u.maxHP),
                facingRadians: facingRadians(u.facing),
                tileX: Int(u.tileX),
                tileZ: Int(u.tileY),
                kind: identByType[u.typeID] ?? "",
                spriteFrame: Int(u.spriteFrame),
                spriteMirror: u.spriteMirror != 0
            ))
            if u.selected != 0, u.alive != 0, selectedID == nil {
                selectedID = id
            }
        }

        // Asset catalog: present only when the engine reported any art
        // descriptor (tileset or a non-empty sprite path). Absent → procedural.
        let tilesetInfo = engine.tileset.map {
            TabletopTilesetInfo(
                imagePath: $0.imagePath,
                pixelTileWidth: Int($0.pixelTileWidth),
                pixelTileHeight: Int($0.pixelTileHeight),
                imageWidth: Int($0.imageWidth),
                imageHeight: Int($0.imageHeight),
                name: $0.name,
                pathRoot: TabletopTilesetPathRoot(rawValue: $0.pathRoot) ?? .dataRoot)
        }
        let assets: TabletopAssetCatalog?
        if tilesetInfo != nil || !spriteByIdent.isEmpty {
            assets = TabletopAssetCatalog(tileset: tilesetInfo, unitTypes: spriteByIdent)
        } else {
            assets = nil
        }

        return TabletopGameplaySnapshot(
            version: TabletopGameplaySnapshot.currentVersion,
            mapSize: TabletopMapSize(width: width, height: height),
            terrain: terrain,
            fogMask: fog,
            units: units,
            selection: TabletopGameplaySelection(selectedUnitID: selectedID),
            assets: assets
        )
    }

    // MARK: Field mappings

    /// Engine facing byte (0-255, 0 = north, clockwise) → radians.
    public static func facingRadians(_ facing: UInt8) -> Double {
        Double(facing) / 256.0 * (2.0 * .pi)
    }

    /// A tile is drawn as revealed when it is currently visible or was
    /// previously explored; only never-seen tiles stay fogged. Retained as the
    /// binary projection of `fogVisibility` for backward-compatible callers.
    public static func isRevealed(_ fogState: UInt8) -> Bool {
        switch EngineFogState(rawValue: fogState) {
        case .visible, .explored: return true
        case .unseen, .none:      return false
        }
    }

    /// Maps the engine fog byte to the canonical three-state UI visibility. An
    /// unknown/out-of-range byte is treated as `.unexplored` (safest: hides
    /// rather than discloses).
    public static func fogVisibility(_ fogState: UInt8) -> TabletopFogVisibility {
        switch EngineFogState(rawValue: fogState) {
        case .visible:       return .visible
        case .explored:      return .explored
        case .unseen, .none: return .unexplored
        }
    }

    /// Maps the engine render-category byte (ABI v4) to the UI category. An
    /// unknown byte is treated as `.mobile`.
    public static func renderCategory(_ raw: UInt8) -> TabletopRenderCategory {
        switch EngineRenderCategory(rawValue: raw) {
        case .building:    return .building
        case .resource:    return .resource
        case .mobile, .none: return .mobile
        }
    }

    /// Maps the engine terrain class to the UI's terrain palette. Classes with
    /// no direct UI equivalent fold onto the nearest kind (wall→rock,
    /// unknown→grass). Coast remains distinct so mixed shoreline frames are
    /// not recessed as whole water tiles by the 2.5D renderer.
    public static func terrainKind(_ terrainClass: UInt8) -> TabletopTerrainKind {
        switch EngineTerrainClass(rawValue: terrainClass) {
        case .grass:   return .grass
        case .dirt:    return .dirt
        case .water:   return .water
        case .rock:    return .rock
        case .forest:  return .forest
        case .coast:   return .coast
        case .wall:    return .rock
        case .unknown, .none: return .grass
        }
    }
}
