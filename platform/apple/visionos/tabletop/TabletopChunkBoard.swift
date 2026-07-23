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

/// Bridges the framework-free substrate slab geometry to a `MeshDescriptor`.
extension TabletopBoardMeshData {
    func meshDescriptor(name: String = "boardSubstrate") -> MeshDescriptor {
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
    /// The thick board substrate/frame slab drawn below the terrain to give the
    /// board visible 2.5D depth. One entity for the whole board.
    private var substrateEntity:  ModelEntity?
    /// Upright viewer-facing tree billboards (decimated for a bounded count),
    /// with their board-plane XZ position for per-frame yaw-toward-viewer.
    private var treeEntities: [(entity: ModelEntity, x: Float, z: Float)] = []
    /// Incremented each time a chunk is (re)built; async atlas completions
    /// compare their captured generation to the current value and abort if
    /// a newer rebuild has superseded them.
    private var chunkGeneration:  [TabletopChunkKey: Int] = [:]
    /// Incremented each time the shared tree material is (re)requested;
    /// mirrors `chunkGeneration`'s per-chunk stale-completion guard so a
    /// superseded in-flight tree-material decode (from a tileset that has
    /// since changed again) cannot overwrite a newer one.
    private var treeGeneration = 0

    // MARK: State

    private var fogMap:  TabletopFogMap?
    private var mapFit:  TabletopMapFit?
    private var snapshot: TabletopGameplaySnapshot?
    /// Board-local Y of each map tile's top surface (terrain relief), keyed by
    /// tileKey. Unit anchoring and the relief-following fog mesh read this.
    private var heightByKey: [Int: Float] = [:]

    // MARK: Readiness

    private var buildStart: CFAbsoluteTime = 0
    public private(set) var totalChunks:     Int = 0
    public private(set) var atlasReadyCount: Int = 0

    /// Streaming-progress snapshot; `readiness.isStable` becomes true once every
    /// terrain chunk has upgraded from its procedural placeholder to real art.
    public var readiness: TabletopBoardReadiness {
        TabletopBoardReadiness(totalChunks: totalChunks, atlasReadyCount: atlasReadyCount)
    }
    /// Set once, when the board first reaches the stable-ready state, so the
    /// transition is logged exactly once.
    private var didLogStable = false

    // Background queue for all CGImage / atlas work.
    private let decodeQueue = DispatchQueue(
        label: "org.peonpad.visionos.tabletop.chunkboard", qos: .userInitiated)

    // MARK: - Init

    public init(chunkTiles: Int = TabletopChunkLayout.defaultChunkTiles) {
        self.chunkTiles = chunkTiles
    }

    /// Board-local Y of the top surface of tile (tileX, tileZ), from terrain
    /// relief. Falls back to the ground baseline for unknown tiles. Read by the
    /// board view to stand unit billboards on the correct terrain height.
    public func terrainHeight(tileX: Int, tileZ: Int) -> Float {
        heightByKey[TabletopChunkLayout.tileKey(tileX, tileZ)]
            ?? TabletopBoardElevation.terrainSurfaceY
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

        tabletopEngineLog("[Tabletop] build: map=\(mapW)x\(mapH) chunks=\(cx)x\(cz)=\(totalChunks) terrain=\(snapshot.terrain.count) assets=\(snapshot.assets != nil ? "real" : "none")")

        // Index terrain tiles for fast chunk lookup.
        let terrainByKey: [Int: TabletopTerrainTile] = Dictionary(
            uniqueKeysWithValues: snapshot.terrain.map {
                (TabletopChunkLayout.tileKey($0.tileX, $0.tileZ), $0)
            })

        tabletopEngineLog("[Tabletop] build: terrainByKey indexed (\(terrainByKey.count) entries)")

        // Per-tile relief heights drive the terrain geometry, unit anchoring
        // and the relief-following fog mesh.
        heightByKey = Self.computeHeights(terrainByKey: terrainByKey)

        // A directional key light so the terrain relief cliffs and the substrate
        // frame shade with clear light/dark contrast — the passthrough
        // image-based light alone reads too flat for the elevation to register.
        addBoardLight(to: boardRoot)

        // Build the thick substrate/frame slab first so it sits beneath the
        // terrain surface and gives the board visible 2.5D depth.
        buildSubstrate(snapshot: snapshot, fit: fit, to: boardRoot)

        // Build one ModelEntity per chunk.
        for chunkZ in 0..<cz {
            for chunkX in 0..<cx {
                let key = TabletopChunkKey(chunkX: chunkX, chunkZ: chunkZ)
                chunkGeneration[key] = (chunkGeneration[key] ?? 0) + 1
                tabletopEngineLog("[Tabletop] build: chunk \(chunkX).\(chunkZ) starting")
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
                tabletopEngineLog("[Tabletop] build: chunk \(chunkX).\(chunkZ) added")
            }
        }

        tabletopEngineLog("[Tabletop] build: all terrain chunks done, building fog")

        // Build single fog entity.
        buildFogEntity(snapshot: snapshot, fit: fit, to: boardRoot)

        // Build upright tree billboards for forest tiles (decimated).
        buildTrees(snapshot: snapshot, fit: fit, to: boardRoot,
                   materialProvider: materialProvider)

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

        // Refresh relief heights for the changed tiles so the rebuilt chunk
        // meshes (and adjacent skirts) use the new elevation.
        for tile in changedTiles {
            heightByKey[TabletopChunkLayout.tileKey(tile.tileX, tile.tileZ)] =
                TabletopTerrainRelief.height(tile.kind)
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
                    guard TabletopAtlasCompletionGate.accepts(
                        requestGeneration: gen,
                        currentGeneration: self.chunkGeneration[key] ?? 0) else { return }  // stale guard
                    entity.model?.materials = [material]
                    self.noteAtlasReady(chunkX: key.chunkX, chunkZ: key.chunkZ,
                                        reason: "terrain change")
                }
            }
        }
    }

    /// Forces every terrain chunk and the shared tree material to re-request
    /// their real-art textures against `tileset`, even though no individual
    /// terrain tile's value changed. Call when the tileset descriptor's
    /// render-relevant identity itself changed between snapshots (see
    /// `TabletopBoardReconciler.tilesetChanged`) — e.g. the engine's
    /// exported-tileset path transitioned from the raw asset to the
    /// generated cache, or from one generated version to the next (see
    /// PeonPadTabletopBridge.cpp's ExportExpandedTilesetPNG /
    /// TabletopTilesetExportCache) — since existing chunk/tree materials
    /// otherwise stay bound to the old tileset forever: `updateTerrainTiles`
    /// alone only rebuilds chunks containing a tile whose *value* changed,
    /// leaving every chunk with no changed tile silently stale.
    ///
    /// Passing every terrain tile (not just ones whose value changed) marks
    /// every chunk dirty in `updateTerrainTiles`, so each one rebuilds its
    /// mesh + atlas against the new tileset and bumps its `chunkGeneration`
    /// — both re-requesting real art and guarding against a stale in-flight
    /// completion from the *old* tileset landing after the new one.
    public func refreshForTilesetChange(
        snapshot next: TabletopGameplaySnapshot,
        tileset: TabletopTilesetInfo?,
        materialProvider: WargusTabletopMaterialProvider?
    ) {
        updateTerrainTiles(next.terrain, tileset: tileset, materialProvider: materialProvider)
        refreshTreeMaterial(snapshot: next, tileset: tileset, materialProvider: materialProvider)
    }

    // MARK: - Incremental fog update

    /// Updates the fog overlay for changed tiles.  Rebuilds the fog texture for
    /// the affected region; the entire texture is replaced (128 × 128 = tiny).
    /// Applies the full three-state visibility (so explored↔visible transitions
    /// show) and logs per-state counts + the transition batch for diagnostics.
    public func updateFogTiles(_ changedTiles: [TabletopFogTile]) {
        guard !changedTiles.isEmpty, var fog = fogMap else { return }
        var toVisible = 0, toExplored = 0, toUnexplored = 0
        for tile in changedTiles {
            switch tile.visibility {
            case .visible:    toVisible += 1
            case .explored:   toExplored += 1
            case .unexplored: toUnexplored += 1
            }
            fog.setVisibility(tile.visibility, tileX: tile.tileX, tileZ: tile.tileZ)
        }
        fogMap = fog
        applyFogTexture(fog)
        tabletopEngineLog(
            "[Tabletop] fog update: \(changedTiles.count) transitions "
            + "(→visible \(toVisible), →explored \(toExplored), →unexplored \(toUnexplored)); "
            + "now visible=\(fog.visibleCount) explored=\(fog.exploredCount) "
            + "unexplored=\(fog.unexploredCount)")
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
            let material: Material = procMat ?? SimpleMaterial(color: .gray, roughness: 1, isMetallic: false)
            entity = ModelEntity(mesh: mesh, materials: [material])
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
                guard TabletopAtlasCompletionGate.accepts(
                    requestGeneration: gen,
                    currentGeneration: self.chunkGeneration[key] ?? 0) else { return }  // stale guard
                entity.model?.materials = [material]
                self.noteAtlasReady(chunkX: key.chunkX, chunkZ: key.chunkZ, reason: nil)
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

        tabletopEngineLog("[Tabletop] chunk \(chunkX).\(chunkZ): tiles=\(tiles.count) slots=\(slotMap.slotCount)")

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

        // Relief tiles carry a per-tile height; skirts are emitted where a
        // neighbour (looked up across the whole map) is lower, so elevation
        // changes show real shaded edges. (Trees are separate billboards.)
        let reliefTiles: [(tileX: Int, tileZ: Int, graphicIndex: Int?, height: Float)] =
            tiles.map { ($0.tileX, $0.tileZ, $0.graphicIndex,
                         self.heightByKey[TabletopChunkLayout.tileKey($0.tileX, $0.tileZ)]
                             ?? TabletopBoardElevation.terrainSurfaceY) }

        tabletopEngineLog("[Tabletop] chunk \(chunkX).\(chunkZ): building relief geometry")
        let geo = TabletopTerrainChunkMeshBuilder.buildRelief(
            tiles: reliefTiles, fit: fit, slotMap: slotMap,
            heightAt: { [heightByKey] x, z in heightByKey[TabletopChunkLayout.tileKey(x, z)] },
            edgeFloorY: TabletopBoardElevation.substrateTopY)
        tabletopEngineLog("[Tabletop] chunk \(chunkX).\(chunkZ): geo verts=\(geo.positions.count) tris=\(geo.triangleIndices.count/3)")
        let mesh = try? MeshResource.generate(from: [geo.meshDescriptor(
            name: "chunk.\(chunkX).\(chunkZ)")])
        tabletopEngineLog("[Tabletop] chunk \(chunkX).\(chunkZ): mesh=\(mesh != nil ? "ok" : "nil")")
        return (mesh, slotMap, slotToKind)
    }

    // MARK: - Private: procedural atlas material

    /// Builds a tiny N × 1-pixel texture (one colour per atlas slot) and wraps
    /// it in a **lit** `PhysicallyBasedMaterial`.  Used as an immediate
    /// procedural placeholder while real tile art is decoded in the background.
    /// Lit (not unlit) so the relief cliffs already shade before real art lands.
    private func makeProceduralAtlasMaterial(
        slotMap:    TabletopAtlasSlotMap,
        slotToKind: [Int: TabletopTerrainKind]
    ) -> PhysicallyBasedMaterial? {
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

        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: .white, texture: .init(texture))
        mat.roughness = 1.0
        mat.metallic  = 0.0
        return mat
    }

    // MARK: - Private: tree billboards

    /// Builds upright, viewer-facing tree billboards for forest tiles. Forest is
    /// top-down tileset art (no side sprite), so trees are rendered as discrete
    /// billboard cards standing on the forest ground — decimated to a bounded
    /// count so a densely-forested map stays performant. All trees share one
    /// material (the real forest tile texture once decoded), so this adds far
    /// fewer entities than one-per-tile and no per-tile decode.
    private func buildTrees(
        snapshot:  TabletopGameplaySnapshot,
        fit:       TabletopMapFit,
        to boardRoot: Entity,
        materialProvider: WargusTabletopMaterialProvider?
    ) {
        let forest = snapshot.terrain.filter { $0.kind == .forest }
        guard !forest.isEmpty else {
            tabletopEngineLog("[Tabletop] trees: no forest tiles")
            return
        }
        let stride = TabletopTreePlacement.stride(forestTileCount: forest.count)

        // Tree card sized relative to the tile so it scales with the map; a
        // couple of tiles tall so it reads as a standing tree, not a decal.
        let cardH = max(fit.tileSize * 3.0, 0.014)
        let cardW = max(fit.tileSize * 2.0, 0.010)
        let mesh  = Self.makeTreeCardMesh(width: cardW, height: cardH)
        // Procedural forest-green until the real forest tile texture decodes.
        let procMat = translucentUnlitMaterial(
            UIColor(hue: 0.34, saturation: 0.55, brightness: 0.32, alpha: 1))

        var placed = 0
        for tile in forest
        where TabletopTreePlacement.isPlacementTile(
            tileX: tile.tileX, tileZ: tile.tileZ, stride: stride) {
            let c = fit.tileCenter(tileX: tile.tileX, tileZ: tile.tileZ)
            let y = heightByKey[TabletopChunkLayout.tileKey(tile.tileX, tile.tileZ)]
                ?? TabletopBoardElevation.terrainSurfaceY
            let e = ModelEntity(mesh: mesh, materials: [procMat])
            e.name = "board.tree.\(tile.tileX).\(tile.tileZ)"
            // Feet on the terrain; the card's centre sits half its height up.
            e.position = SIMD3<Float>(c.x, y + cardH / 2, c.z)
            // System-driven billboard: RealityKit re-orients the card to face
            // the real camera every frame (robust in the Simulator, where the
            // head anchor does not track a moving viewpoint reliably).
            e.components.set(BillboardComponent())
            boardRoot.addChild(e)
            treeEntities.append((entity: e, x: c.x, z: c.z))
            placed += 1
        }

        // Upgrade all trees to the real forest tile art (one shared decode).
        refreshTreeMaterial(snapshot: snapshot, tileset: snapshot.assets?.tileset,
                            materialProvider: materialProvider)

        tabletopEngineLog(
            "[Tabletop] trees: forest=\(forest.count) stride=\(stride) billboards=\(placed)")
    }

    /// Requests the shared tree material against `tileset`'s current
    /// forest-tile art and applies it to every placed tree billboard when it
    /// decodes. Guarded by `treeGeneration` so a stale in-flight decode (from
    /// a tileset the caller has since superseded with another refresh) can
    /// never overwrite a newer result — mirroring `chunkGeneration`'s
    /// per-chunk stale-completion guard.
    private func refreshTreeMaterial(
        snapshot: TabletopGameplaySnapshot,
        tileset: TabletopTilesetInfo?,
        materialProvider: WargusTabletopMaterialProvider?
    ) {
        guard !treeEntities.isEmpty,
              let materialProvider,
              let gi = snapshot.terrain.first(where: { $0.kind == .forest })?.graphicIndex
        else { return }

        treeGeneration += 1
        let gen = treeGeneration
        materialProvider.terrainMaterial(
            graphicIndex: gi, tileset: tileset
        ) { [weak self] material in
            guard let self else { return }
            guard TabletopAtlasCompletionGate.accepts(
                requestGeneration: gen, currentGeneration: self.treeGeneration) else { return }  // stale guard
            for t in self.treeEntities { t.entity.model?.materials = [material] }
            tabletopEngineLog("[Tabletop] trees: real forest texture applied")
        }
    }

    /// A double-sided vertical quad for a tree billboard, centred on the origin.
    /// UVs come from `TabletopTreeCard` so the (top-down) forest tile texture
    /// stands upright (the tile's south/near edge, v=1, at the card top) rather
    /// than upside down. Double-sided so it is never back-face culled regardless
    /// of which way the billboard turns.
    private static func makeTreeCardMesh(width: Float, height: Float) -> MeshResource {
        let hw = width / 2, hh = height / 2
        let tl = SIMD3<Float>(-hw,  hh, 0)
        let bl = SIMD3<Float>(-hw, -hh, 0)
        let br = SIMD3<Float>( hw, -hh, 0)
        let tr = SIMD3<Float>( hw,  hh, 0)
        let uv = TabletopTreeCard.cornerUVs()
        let uvTL = uv.tl, uvBL = uv.bl, uvBR = uv.br, uvTR = uv.tr

        // Front (+Z) then back (−Z), each with its own vertices/normal so the
        // texture reads upright from both sides.
        let positions = [tl, bl, br, tr,  tl, bl, br, tr]
        let normals   = [SIMD3<Float>(0,0,1), .init(0,0,1), .init(0,0,1), .init(0,0,1),
                         SIMD3<Float>(0,0,-1), .init(0,0,-1), .init(0,0,-1), .init(0,0,-1)]
        let uvs       = [uvTL, uvBL, uvBR, uvTR,  uvTL, uvBL, uvBR, uvTR]
        let indices: [UInt32] = [
            0, 1, 2,  0, 2, 3,        // front, CCW from +Z
            4, 6, 5,  4, 7, 6,        // back, CCW from −Z
        ]
        var desc = MeshDescriptor(name: "treeCard")
        desc.positions          = MeshBuffer(positions)
        desc.normals            = MeshBuffer(normals)
        desc.textureCoordinates = MeshBuffer(uvs)
        desc.primitives         = .triangles(indices)
        return (try? MeshResource.generate(from: [desc]))
            ?? .generatePlane(width: width, height: height)
    }

    // MARK: - Private: substrate slab

    /// Builds the thick board substrate/frame slab beneath the terrain so the
    /// board reads as a physical 2.5D object with visible depth, instead of a
    /// flat decal. Sized to the terrain area plus a frame border.
    private func buildSubstrate(
        snapshot:  TabletopGameplaySnapshot,
        fit:       TabletopMapFit,
        to boardRoot: Entity
    ) {
        let (w, d) = TabletopSubstrateLayout.substrateExtent(
            fit: fit, mapWidth: snapshot.mapSize.width, mapHeight: snapshot.mapSize.height)
        let geo  = TabletopSubstrateMeshBuilder.build(width: w, depth: d)
        let mesh = (try? MeshResource.generate(from: [geo.meshDescriptor()]))
            ?? .generateBox(size: SIMD3<Float>(
                w, TabletopBoardElevation.substrateThickness, d))
        // Opaque, matte slab so the board frame is clearly distinct from the
        // terrain surface above it and its side faces shade under the scene's
        // image-based lighting — a real depth cue. No proprietary art.
        let mat = SimpleMaterial(
            color: UIColor(red: 0.20, green: 0.14, blue: 0.09, alpha: 1),
            roughness: 0.9,
            isMetallic: false)
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.name = "board.substrate"
        boardRoot.addChild(entity)
        substrateEntity = entity
        tabletopEngineLog(
            "[Tabletop] substrate slab: "
            + "extent=\(String(format: "%.3f", w))x\(String(format: "%.3f", d))m "
            + "thickness=\(String(format: "%.3f", TabletopBoardElevation.substrateThickness))m "
            + "top=\(TabletopBoardElevation.substrateTopY) bottom=\(TabletopBoardElevation.substrateBottomY)")
    }

    /// Records one chunk's real-art atlas arrival and logs the stable-ready
    /// transition exactly once, when the last chunk settles.
    private func noteAtlasReady(chunkX: Int, chunkZ: Int, reason: String?) {
        atlasReadyCount += 1
        let suffix = reason.map { " (\($0))" } ?? ""
        tabletopEngineLog(
            "[Tabletop] atlas ready chunk \(atlasReadyCount)/\(totalChunks) "
            + "(\(chunkX).\(chunkZ))\(suffix)")
        if !didLogStable, readiness.isStable {
            didLogStable = true
            tabletopEngineLog(
                "[Tabletop] board stable-ready: all \(totalChunks) chunks upgraded to real art")
        }
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
            fog.setVisibility(tile.visibility, tileX: tile.tileX, tileZ: tile.tileZ)
        }
        fogMap = fog
        tabletopEngineLog(
            "[Tabletop] fog init: visible=\(fog.visibleCount) "
            + "explored=\(fog.exploredCount) unexplored=\(fog.unexploredCount) "
            + "of \(mapW * mapH) tiles")

        // The fog is a per-tile mesh that follows the terrain relief: each tile
        // quad floats a fixed gap above that tile's own terrain height, so the
        // veil hugs valleys and rises over highlands without ever being
        // coplanar with (or clipping through) the terrain. Heights are baked in,
        // so the entity stays at the board origin and only its texture updates.
        let mesh   = makeFogReliefMesh(mapWidth: mapW, mapHeight: mapH, fit: fit)
        let mat    = makeFogMaterial(for: fog)
        let entity = ModelEntity(mesh: mesh, materials: [mat])
        entity.name     = "board.fog"
        entity.position = [0, 0, 0]
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
            // Straight alpha blending from the fog texture: revealed tiles are
            // fully transparent (alpha 0), hidden tiles a dark veil. A single,
            // consistent blend mode (no simultaneous alpha-test cutout) keeps
            // the elevated fog plane from flickering as it re-uploads.
            mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            return mat
        }
        // Fallback: solid dark overlay.
        return translucentUnlitMaterial(UIColor(white: 0.06, alpha: 0.88))
    }

    /// Builds the relief-following fog mesh: one quad per map tile, positioned a
    /// fixed gap above that tile's terrain height, with the four corners sampling
    /// the tile's own texel in the fog texture (UV = tile-centre).  Baking the
    /// heights in keeps the fog a single entity whose texture (not geometry)
    /// updates as fog-of-war changes.
    private func makeFogReliefMesh(mapWidth: Int, mapHeight: Int, fit: TabletopMapFit) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals:   [SIMD3<Float>] = []
        var uvs:       [SIMD2<Float>] = []
        var indices:   [UInt32]       = []
        let ht  = fit.tileSize / 2
        let up  = SIMD3<Float>(0, 1, 0)
        let gap = TabletopBoardElevation.fogGap
        positions.reserveCapacity(mapWidth * mapHeight * 4)

        for tz in 0..<mapHeight {
            for tx in 0..<mapWidth {
                let c = fit.tileCenter(tileX: tx, tileZ: tz)
                let y = (heightByKey[TabletopChunkLayout.tileKey(tx, tz)]
                         ?? TabletopBoardElevation.terrainSurfaceY) + gap
                let base = UInt32(positions.count)
                positions.append(SIMD3<Float>(c.x - ht, y, c.z - ht)) // NW
                positions.append(SIMD3<Float>(c.x + ht, y, c.z - ht)) // NE
                positions.append(SIMD3<Float>(c.x + ht, y, c.z + ht)) // SE
                positions.append(SIMD3<Float>(c.x - ht, y, c.z + ht)) // SW
                normals.append(contentsOf: [up, up, up, up])
                // All four corners sample this tile's own texel centre.
                let u = (Float(tx) + 0.5) / Float(mapWidth)
                let v = (Float(tz) + 0.5) / Float(mapHeight)
                let uv = SIMD2<Float>(u, v)
                uvs.append(contentsOf: [uv, uv, uv, uv])
                // Same CCW-from-above winding as the terrain tops.
                indices.append(contentsOf: [base, base + 2, base + 1,
                                            base, base + 3, base + 2])
            }
        }

        var desc = MeshDescriptor(name: "fogRelief")
        desc.positions          = MeshBuffer(positions)
        desc.normals            = MeshBuffer(normals)
        desc.textureCoordinates = MeshBuffer(uvs)
        desc.primitives         = .triangles(indices)
        return (try? MeshResource.generate(from: [desc]))
            ?? .generatePlane(width: Float(mapWidth) * fit.tileSize,
                              depth: Float(mapHeight) * fit.tileSize)
    }

    // MARK: - Private: relief heights + lighting

    /// Maps each terrain tile to its relief height (framework-free math).
    private static func computeHeights(
        terrainByKey: [Int: TabletopTerrainTile]
    ) -> [Int: Float] {
        var heights: [Int: Float] = [:]
        heights.reserveCapacity(terrainByKey.count)
        for (key, tile) in terrainByKey {
            heights[key] = TabletopTerrainRelief.height(tile.kind)
        }
        return heights
    }

    /// Adds a single angled directional key light (with a soft shadow) to the
    /// board root so terrain relief cliffs and the substrate frame read with
    /// clear light/dark contrast and units cast contact shadows onto terrain.
    private func addBoardLight(to boardRoot: Entity) {
        let light = DirectionalLight()
        light.name = "board.keyLight"
        light.light.intensity = 2_600
        light.shadow = DirectionalLightComponent.Shadow(
            maximumDistance: 2.0, depthBias: 2.0)
        // Angle down and across the board so cliffs facing the light are bright
        // and their shadowed sides are dark — the elevation depth cue.
        light.orientation =
            simd_quatf(angle: -.pi / 3, axis: [1, 0, 0]) *
            simd_quatf(angle:  .pi / 5, axis: [0, 1, 0])
        boardRoot.addChild(light)
    }
}
