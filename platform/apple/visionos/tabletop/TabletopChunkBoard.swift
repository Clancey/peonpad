// TabletopChunkBoard.swift
//
// RealityKit entity manager for the chunked terrain surface + single-entity
// fog-of-war overlay.  Replaces the 32 768-entity per-tile explosion that
// `TabletopBoardBuilder.addSurface()` produced for a 128 × 128 map.
//
// Architecture:
//   Terrain — 1 ModelEntity per 32 × 32-tile chunk.
//             • Initial material: a tiny N × 1-pixel procedural colour texture
//               (N = unique graphicIndex count in the chunk), visible immediately.
//             • Progressive upgrade: a decoded horizontal-strip atlas applied
//               asynchronously so the board never blocks the main thread.
//   Fog     — 1 ModelEntity covering the entire board with a mapWidth × mapHeight
//             RGBA texture (1 pixel per tile).  Rebuilt on every snapshot update.
//
// Entity count for a 128 × 128 map (chunkTiles = 32): 4 × 4 = 16 terrain
// chunks + 1 fog entity = 17 total, vs 32 768 before this change.
//
// Readiness:
//   `[Tabletop] board built` is logged immediately after the synchronous phase
//   (entity count, chunk count, map size, asset mode, build time).
//   `[Tabletop] atlas ready chunk X/Y` is logged as each real-art atlas arrives.
import RealityKit
import UIKit

// MARK: - Chunk key

struct TabletopChunkKey: Hashable {
    let chunkX: Int
    let chunkZ: Int
}

// MARK: - Terrain kind colour

extension TabletopTerrainKind {
    /// RGBA (pre-multiplied) byte triple for the procedural atlas placeholder.
    var rgbaPM: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .grass:  return (179, 179, 179)
        case .dirt:   return (115, 115, 115)
        case .water:  return ( 29,  50, 115)
        case .rock:   return ( 56,  56,  56)
        case .forest: return ( 38,  76,  38)
        }
    }
}

// MARK: - RealityKit extension bridge

/// Converts framework-free chunk geometry to a `MeshDescriptor` for
/// `MeshResource.generate(from:)`.  Defined here (where RealityKit is imported)
/// so `TabletopChunkGeometry.swift` stays framework-free.
extension TabletopTerrainChunkGeometry {
    func meshDescriptor(name: String = "terrainChunk") -> MeshDescriptor {
        var desc = MeshDescriptor(name: name)
        desc.positions           = MeshBuffer(positions)
        desc.normals             = MeshBuffer(normals)
        desc.textureCoordinates  = MeshBuffer(textureCoordinates)
        desc.primitives          = .triangles(triangleIndices)
        return desc
    }
}

// MARK: - TabletopChunkBoard

/// Manages the chunked terrain and fog-overlay entities for the tabletop board.
/// All methods are `@MainActor`; background decode work is dispatched explicitly
/// to `decodeQueue` and Task-hopped back to the main actor for scene mutations.
@MainActor
public final class TabletopChunkBoard {

    // MARK: Configuration

    /// Tiles per chunk side.  Default 32 → 16 chunks for a 128 × 128 map.
    public let chunkTiles: Int

    // MARK: Entity registry

    private var chunkEntities:    [TabletopChunkKey: ModelEntity] = [:]
    private var fogEntity:        ModelEntity?
    /// Incremented each time a chunk is (re)built; async atlas completions
    /// compare their captured generation to the current value and abort if
    /// a newer rebuild has superseded them.
    private var chunkGeneration:  [TabletopChunkKey: Int] = [:]

    // MARK: State

    private var fogMap:  TabletopFogMap?
    private var mapFit:  TabletopMapFit?
    private var snapshot: TabletopGameplaySnapshot?

    // MARK: Readiness

    private var buildStart: CFAbsoluteTime = 0
    public private(set) var totalChunks:     Int = 0
    public private(set) var atlasReadyCount: Int = 0

    // Background queue for all CGImage / atlas work.
    private let decodeQueue = DispatchQueue(
        label: "org.peonpad.visionos.tabletop.chunkboard", qos: .userInitiated)

    // MARK: - Init

    public init(chunkTiles: Int = TabletopChunkLayout.defaultChunkTiles) {
        self.chunkTiles = chunkTiles
    }

    // MARK: - Build

    /// Builds the chunked terrain surface and fog overlay from the first snapshot.
    ///
    /// Returns synchronously after creating all entities with procedural materials;
    /// real atlas textures are applied asynchronously via `materialProvider`.
    public func build(
        snapshot:         TabletopGameplaySnapshot,
        fit:              TabletopMapFit,
        to boardRoot:     Entity,
        materialProvider: WargusTabletopMaterialProvider?
    ) {
        buildStart     = CFAbsoluteTimeGetCurrent()
        self.mapFit    = fit
        self.snapshot  = snapshot

        let mapW = snapshot.mapSize.width
        let mapH = snapshot.mapSize.height
        let (cx, cz) = TabletopChunkLayout.chunkCount(
            mapWidth: mapW, mapHeight: mapH, chunkTiles: chunkTiles)
        totalChunks = cx * cz

        // Index terrain tiles for fast chunk lookup.
        let terrainByKey: [Int: TabletopTerrainTile] = Dictionary(
            uniqueKeysWithValues: snapshot.terrain.map {
                (TabletopChunkLayout.tileKey($0.tileX, $0.tileZ), $0)
            })

        // Build one ModelEntity per chunk.
        for chunkZ in 0..<cz {
            for chunkX in 0..<cx {
                let key = TabletopChunkKey(chunkX: chunkX, chunkZ: chunkZ)
                chunkGeneration[key] = (chunkGeneration[key] ?? 0) + 1
                let entity = buildChunkEntity(
                    key: key,
                    chunkX: chunkX, chunkZ: chunkZ,
                    mapWidth: mapW, mapHeight: mapH,
                    fit: fit, terrainByKey: terrainByKey,
                    tileset: snapshot.assets?.tileset,
                    materialProvider: materialProvider)
                entity.name = "board.chunk.\(chunkX).\(chunkZ)"
                boardRoot.addChild(entity)
                chunkEntities[key] = entity
            }
        }

        // Build single fog entity.
        buildFogEntity(snapshot: snapshot, fit: fit, to: boardRoot)

        let elapsed = CFAbsoluteTimeGetCurrent() - buildStart
        tabletopEngineLog(
            "[Tabletop] board built from first snapshot: "
            + "map=\(mapW)x\(mapH) "
            + "chunks=\(totalChunks) "
            + "entities=\(chunkEntities.count + 1) "
            + "assets=\(snapshot.assets != nil ? "real" : "procedural") "
            + "buildTime=\(String(format: "%.3f", elapsed))s")
    }

    // MARK: - Snapshot tracking

    /// Call after each snapshot diff is applied so future incremental updates
    /// see the latest terrain state.
    public func updateSnapshot(_ next: TabletopGameplaySnapshot) {
        snapshot = next
    }

    // MARK: - Incremental terrain update

    /// Updates terrain materials for tiles whose graphicIndex or kind changed.
    /// Affected chunks are rebuilt (mesh + atlas) since the atlas slot map may
    /// need to change if a new graphicIndex appears (e.g. tree cut → dirt).
    public func updateTerrainTiles(
        _ changedTiles: [TabletopTerrainTile],
        tileset: TabletopTilesetInfo?,
        materialProvider: WargusTabletopMaterialProvider?
    ) {
        guard !changedTiles.isEmpty,
              let fit = mapFit,
              let current = snapshot else { return }

        // Determine which chunks need rebuilding.
        var dirtyChunks = Set<TabletopChunkKey>()
        for tile in changedTiles {
            let (cx, cz) = TabletopChunkLayout.chunkFor(
                tileX: tile.tileX, tileZ: tile.tileZ, chunkTiles: chunkTiles)
            dirtyChunks.insert(TabletopChunkKey(chunkX: cx, chunkZ: cz))
        }

        // Merge the changes into the current snapshot terrain index.
        var terrainByKey: [Int: TabletopTerrainTile] = Dictionary(
            uniqueKeysWithValues: current.terrain.map {
                (TabletopChunkLayout.tileKey($0.tileX, $0.tileZ), $0)
            })
        for tile in changedTiles {
            terrainByKey[TabletopChunkLayout.tileKey(tile.tileX, tile.tileZ)] = tile
        }

        let mapW = current.mapSize.width
        let mapH = current.mapSize.height

        for key in dirtyChunks {
            guard let entity = chunkEntities[key] else { continue }
            let (mesh, slotMap, slotToKind) = buildChunkMeshAndSlotMap(
                chunkX: key.chunkX, chunkZ: key.chunkZ,
                mapWidth: mapW, mapHeight: mapH,
                fit: fit, terrainByKey: terrainByKey)
            guard let mesh else { continue }
            // Increment generation so any in-flight atlas for this chunk is
            // considered stale when it completes.
            chunkGeneration[key] = (chunkGeneration[key] ?? 0) + 1
            let gen = chunkGeneration[key]!
            // Apply procedural material immediately.
            if let procMat = makeProceduralAtlasMaterial(
                slotMap: slotMap, slotToKind: slotToKind) {
                entity.model = ModelComponent(mesh: mesh, materials: [procMat])
            }
            // Kick off real-art atlas upgrade.
            if let materialProvider {
                materialProvider.buildTerrainAtlas(
                    slotMap: slotMap, tileset: tileset
                ) { [weak entity, weak self] material in
                    guard let entity, let material, let self else { return }
                    guard self.chunkGeneration[key] == gen else { return }  // stale guard
                    entity.model?.materials = [material]
                    self.atlasReadyCount += 1
                    tabletopEngineLog(
                        "[Tabletop] atlas updated chunk "
                        + "\(key.chunkX).\(key.chunkZ) (terrain change)")
                }
            }
        }
    }

    // MARK: - Incremental fog update

    /// Updates the fog overlay for changed tiles.  Rebuilds the fog texture for
    /// the affected region; the entire texture is replaced (128 × 128 = tiny).
    public func updateFogTiles(_ changedTiles: [TabletopFogTile]) {
        guard !changedTiles.isEmpty, var fog = fogMap else { return }
        for tile in changedTiles {
            fog.setRevealed(tile.isRevealed, tileX: tile.tileX, tileZ: tile.tileZ)
        }
        fogMap = fog
        applyFogTexture(fog)
    }

    // MARK: - Private: chunk entity construction

    private func buildChunkEntity(
        key: TabletopChunkKey,
        chunkX: Int, chunkZ: Int,
        mapWidth: Int, mapHeight: Int,
        fit: TabletopMapFit,
        terrainByKey: [Int: TabletopTerrainTile],
        tileset: TabletopTilesetInfo?,
        materialProvider: WargusTabletopMaterialProvider?
    ) -> ModelEntity {
        let (mesh, slotMap, slotToKind) = buildChunkMeshAndSlotMap(
            chunkX: chunkX, chunkZ: chunkZ,
            mapWidth: mapWidth, mapHeight: mapHeight,
            fit: fit, terrainByKey: terrainByKey)

        let procMat = makeProceduralAtlasMaterial(slotMap: slotMap, slotToKind: slotToKind)

        let entity: ModelEntity
        if let mesh {
            entity = ModelEntity(mesh: mesh, materials: [procMat ?? translucentUnlitMaterial(.gray)])
        } else {
            entity = ModelEntity()
        }

        // Async: upgrade to real atlas once decoded.
        // Capture the generation at request time; discard the result if a
        // newer rebuild has superseded this request (prevents stale overwrites).
        if let materialProvider, let tileset {
            let gen = chunkGeneration[key] ?? 0
            materialProvider.buildTerrainAtlas(slotMap: slotMap, tileset: tileset) {
                [weak entity, weak self] material in
                guard let entity, let material, let self else { return }
                guard self.chunkGeneration[key] == gen else { return }  // stale guard
                entity.model?.materials = [material]
                self.atlasReadyCount += 1
                tabletopEngineLog(
                    "[Tabletop] atlas ready chunk \(self.atlasReadyCount)/\(self.totalChunks) "
                    + "(\(key.chunkX).\(key.chunkZ))")
            }
        }

        return entity
    }

    /// Builds the chunk mesh and slot map for the given chunk.
    /// Returns (nil, emptySlotMap, emptyDict) when no tiles exist in the chunk.
    private func buildChunkMeshAndSlotMap(
        chunkX: Int, chunkZ: Int,
        mapWidth: Int, mapHeight: Int,
        fit: TabletopMapFit,
        terrainByKey: [Int: TabletopTerrainTile]
    ) -> (MeshResource?, TabletopAtlasSlotMap, [Int: TabletopTerrainKind]) {
        let tileCoords = TabletopChunkLayout.tilesIn(
            chunkX: chunkX, chunkZ: chunkZ,
            mapWidth: mapWidth, mapHeight: mapHeight, chunkTiles: chunkTiles)

        let tiles: [(tileX: Int, tileZ: Int, graphicIndex: Int?)] = tileCoords.map {
            let t = terrainByKey[TabletopChunkLayout.tileKey($0.tileX, $0.tileZ)]
            return (tileX: $0.tileX, tileZ: $0.tileZ, graphicIndex: t?.graphicIndex)
        }
        let slotMap = TabletopAtlasSlotMap(graphicIndices: tiles.map { $0.graphicIndex })

        // slot → terrain kind (from first tile with each slot's graphicIndex)
        var slotToKind: [Int: TabletopTerrainKind] = [:]
        for tc in tileCoords {
            if let t = terrainByKey[TabletopChunkLayout.tileKey(tc.tileX, tc.tileZ)] {
                let s = slotMap.slot(for: t.graphicIndex)
                if slotToKind[s] == nil { slotToKind[s] = t.kind }
            }
        }

        guard !tiles.isEmpty else {
            return (nil, slotMap, slotToKind)
        }

        let geo  = TabletopTerrainChunkMeshBuilder.build(tiles: tiles, fit: fit, slotMap: slotMap)
        let mesh = try? MeshResource.generate(from: [geo.meshDescriptor(
            name: "chunk.\(chunkX).\(chunkZ)")])
        return (mesh, slotMap, slotToKind)
    }

    // MARK: - Private: procedural atlas material

    /// Builds a tiny N × 1-pixel texture (one colour per atlas slot) and wraps
    /// it in an `UnlitMaterial`.  Used as an immediate procedural placeholder
    /// while real tile art is decoded in the background.
    private func makeProceduralAtlasMaterial(
        slotMap:    TabletopAtlasSlotMap,
        slotToKind: [Int: TabletopTerrainKind]
    ) -> UnlitMaterial? {
        let N = slotMap.slotCount
        var raw = [UInt8](repeating: 255, count: N * 4)
        for (slot, kind) in slotToKind {
            guard slot < N else { continue }
            let (r, g, b) = kind.rgbaPM
            raw[slot*4 + 0] = r
            raw[slot*4 + 1] = g
            raw[slot*4 + 2] = b
            raw[slot*4 + 3] = 255
        }
        let data = Data(raw)
        let cs   = CGColorSpaceCreateDeviceRGB()
        let bi   = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage  = CGImage(
                  width: N, height: 1,
                  bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: N * 4,
                  space: cs, bitmapInfo: bi,
                  provider: provider,
                  decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent),
              let texture  = try? TextureResource(
                  image: cgImage,
                  options: .init(semantic: .color))
        else { return nil }

        var mat = UnlitMaterial()
        mat.color = .init(tint: .white, texture: .init(texture))
        return mat
    }

    // MARK: - Private: fog entity

    private func buildFogEntity(
        snapshot:  TabletopGameplaySnapshot,
        fit:       TabletopMapFit,
        to boardRoot: Entity
    ) {
        let mapW = snapshot.mapSize.width
        let mapH = snapshot.mapSize.height

        var fog = TabletopFogMap(mapWidth: mapW, mapHeight: mapH)
        for tile in snapshot.fogMask {
            fog.setRevealed(tile.isRevealed, tileX: tile.tileX, tileZ: tile.tileZ)
        }
        fogMap = fog

        // The fog plane covers the same XZ extent as the tile area so pixel
        // centres align exactly with tile centres (see TabletopFogMap docs).
        let planeW = Float(mapW) * fit.tileSize
        let planeD = Float(mapH) * fit.tileSize
        let mesh   = makeFogPlaneMesh(width: planeW, depth: planeD)
        let mat    = makeFogMaterial(for: fog)
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.name     = "board.fog"
        entity.position = [0, 0.005, 0]   // just above terrain
        boardRoot.addChild(entity)
        fogEntity = entity
    }

    private func applyFogTexture(_ fog: TabletopFogMap) {
        let mat = makeFogMaterial(for: fog)
        fogEntity?.model?.materials = [mat]
    }

    private func makeFogMaterial(for fog: TabletopFogMap) -> UnlitMaterial {
        if let cgImage  = fog.cgImage(),
           let texture  = try? TextureResource(
               image: cgImage, options: .init(semantic: .color)) {
            var mat = UnlitMaterial()
            mat.color    = .init(tint: .white, texture: .init(texture))
            mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            mat.opacityThreshold = 0.1
            return mat
        }
        // Fallback: solid dark overlay.
        return translucentUnlitMaterial(UIColor(white: 0.06, alpha: 0.88))
    }

    /// Custom 4-vertex plane mesh with UV(0,0) at the (−X,−Z) corner so pixel
    /// (tileX, tileZ) in the fog texture maps to the correct board tile.
    private func makeFogPlaneMesh(width: Float, depth: Float) -> MeshResource {
        var desc = MeshDescriptor(name: "fogPlane")
        let hw = width / 2, hd = depth / 2
        // Vertices: (−X,−Z), (+X,−Z), (+X,+Z), (−X,+Z)
        // UV: (0,0),         (1,0),    (1,1),    (0,1)
        // UV v=0 → z=−hd → tileZ=0 (north/UV-top edge)
        desc.positions = MeshBuffer([
            SIMD3<Float>(-hw, 0, -hd),
            SIMD3<Float>( hw, 0, -hd),
            SIMD3<Float>( hw, 0,  hd),
            SIMD3<Float>(-hw, 0,  hd),
        ])
        desc.normals = MeshBuffer([
            SIMD3<Float>(0,1,0), SIMD3<Float>(0,1,0),
            SIMD3<Float>(0,1,0), SIMD3<Float>(0,1,0),
        ])
        desc.textureCoordinates = MeshBuffer([
            SIMD2<Float>(0,0), SIMD2<Float>(1,0),
            SIMD2<Float>(1,1), SIMD2<Float>(0,1),
        ])
        desc.primitives = .triangles([
            // Same CCW-from-above winding as terrain chunks:
            // cross((SE−NW),(NE−SE)) = +Y ✓
            0, 2, 1,   // NW→SE→NE
            0, 3, 2,   // NW→SW→SE
        ])
        return (try? MeshResource.generate(from: [desc]))
            ?? .generatePlane(width: width, depth: depth)
    }
}
