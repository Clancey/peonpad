// TabletopChunkGeometry.swift
//
// Framework-free chunk layout and terrain-chunk mesh geometry for the visionOS
// tabletop board.  Partitions an arbitrary tile map into fixed-size rectangular
// chunks and builds flat vertex/index buffers for use with RealityKit's
// MeshDescriptor API.  All types here are testable with plain swiftc on the
// host Mac — no Simulator, RealityKit, or UIKit required.
//
//   ./scripts/test-visionos-tabletop-chunks.sh
import Foundation

// MARK: - Chunk layout

/// Partitions a tile map into fixed-size rectangular chunks.
public enum TabletopChunkLayout {

    /// Default chunk side in tiles. 32 × 32 = 1 024 tiles per chunk; a 128 × 128
    /// map produces 4 × 4 = 16 chunks instead of 32 768 per-tile entities.
    public static let defaultChunkTiles = 32

    /// Number of chunks in each axis for a map of the given size.
    /// Returns at least (1, 1) for degenerate maps.
    public static func chunkCount(
        mapWidth: Int, mapHeight: Int,
        chunkTiles: Int = defaultChunkTiles
    ) -> (cx: Int, cz: Int) {
        let n = max(1, chunkTiles)
        return (
            cx: max(1, (mapWidth  + n - 1) / n),
            cz: max(1, (mapHeight + n - 1) / n)
        )
    }

    /// Tile coordinate of the top-left tile in chunk (chunkX, chunkZ).
    public static func chunkOrigin(
        chunkX: Int, chunkZ: Int,
        chunkTiles: Int = defaultChunkTiles
    ) -> (tileX: Int, tileZ: Int) {
        let n = max(1, chunkTiles)
        return (chunkX * n, chunkZ * n)
    }

    /// Which chunk owns tile (tileX, tileZ).
    public static func chunkFor(
        tileX: Int, tileZ: Int,
        chunkTiles: Int = defaultChunkTiles
    ) -> (chunkX: Int, chunkZ: Int) {
        let n = max(1, chunkTiles)
        return (tileX / n, tileZ / n)
    }

    /// All tile coordinates in chunk (chunkX, chunkZ), clamped to map bounds.
    /// Returns an empty array when the chunk origin lies outside the map.
    public static func tilesIn(
        chunkX: Int, chunkZ: Int,
        mapWidth: Int, mapHeight: Int,
        chunkTiles: Int = defaultChunkTiles
    ) -> [(tileX: Int, tileZ: Int)] {
        let n = max(1, chunkTiles)
        let sx = chunkX * n, sz = chunkZ * n
        guard sx < mapWidth, sz < mapHeight else { return [] }
        var result: [(Int, Int)] = []
        result.reserveCapacity(n * n)
        for tz in sz..<min(sz + n, mapHeight) {
            for tx in sx..<min(sx + n, mapWidth) {
                result.append((tx, tz))
            }
        }
        return result
    }

    /// Dense, collision-free integer key for tile (tileX, tileZ) in the range
    /// [-9 999, 9 999] — the same convention as TabletopBoardReconciler.
    public static func tileKey(_ tileX: Int, _ tileZ: Int) -> Int {
        (tileX + 10_000) * 20_001 + (tileZ + 10_000)
    }
}

// MARK: - Atlas slot map

/// Maps optional graphic-index values to zero-based atlas column slots.
/// Slots are assigned in first-seen order from the input sequence.
/// `slotCount` is the total number of distinct slots (≥ 1).
public struct TabletopAtlasSlotMap: Sendable {

    public let slotCount: Int

    // nil graphicIndex → nilSlot; non-nil → indexSlots[graphicIndex]
    private let indexSlots: [Int: Int]
    private let nilSlot:    Int?

    /// Ordered entries for atlas assembly: (graphicIndex?, slotIndex).
    public let slotEntries: [(graphicIndex: Int?, slotIndex: Int)]

    /// Builds the slot map from an arbitrary sequence of graphicIndex values.
    /// Duplicate values are collapsed to the same slot.
    public init<S: Sequence>(graphicIndices: S) where S.Element == Int? {
        var idxMap:  [Int: Int] = [:]
        var nilIdx:  Int?       = nil
        var entries: [(Int?, Int)] = []
        var next = 0
        for idx in graphicIndices {
            if let idx {
                if idxMap[idx] == nil {
                    idxMap[idx] = next
                    entries.append((idx, next))
                    next += 1
                }
            } else if nilIdx == nil {
                nilIdx = next
                entries.append((nil, next))
                next += 1
            }
        }
        self.indexSlots = idxMap
        self.nilSlot    = nilIdx
        self.slotEntries = entries
        self.slotCount  = max(1, next)   // ≥1 prevents UV ÷0
    }

    /// Atlas slot index for `graphicIndex`.  Unknown indices fall back to the
    /// nil slot when present, otherwise slot 0.
    public func slot(for graphicIndex: Int?) -> Int {
        if let graphicIndex {
            return indexSlots[graphicIndex] ?? nilSlot ?? 0
        }
        return nilSlot ?? 0
    }
}

// MARK: - Chunk geometry output

/// Flat vertex arrays for one terrain-chunk mesh.
/// All positions are board-local (Y = 0 plane).
public struct TabletopTerrainChunkGeometry {
    public let positions:           [SIMD3<Float>]
    public let normals:             [SIMD3<Float>]
    public let textureCoordinates:  [SIMD2<Float>]
    public let triangleIndices:     [UInt32]

    public var isEmpty: Bool { triangleIndices.isEmpty }
    /// Number of tile quads encoded.
    public var tileCount: Int { triangleIndices.count / 6 }
}

// MARK: - Mesh builder

/// Builds flat terrain-chunk mesh geometry (no RealityKit dependency).
public enum TabletopTerrainChunkMeshBuilder {

    /// Builds a flat terrain-chunk mesh in board-local space.
    ///
    /// Each tile contributes 4 vertices (a quad) and 6 indices (2 triangles).
    /// The UV X axis is divided into `slotMap.slotCount` equal columns — one
    /// per atlas slot — so the same UV layout works for both the tiny
    /// procedural-colour texture and the real decoded-tile atlas:
    ///
    ///   u ∈ [ slot/N,  (slot+1)/N ]   (horizontal atlas column)
    ///   v ∈ [ 0,       1          ]   (full tile height)
    ///
    /// - Parameters:
    ///   - tiles:   (tileX, tileZ, graphicIndex?) for each tile in the chunk.
    ///   - fit:     Board-space tile sizing and centering.
    ///   - slotMap: Atlas layout — maps each graphicIndex to a UV column slot.
    public static func build(
        tiles:   [(tileX: Int, tileZ: Int, graphicIndex: Int?)],
        fit:     TabletopMapFit,
        slotMap: TabletopAtlasSlotMap
    ) -> TabletopTerrainChunkGeometry {
        let count = tiles.count
        var positions = [SIMD3<Float>](); positions.reserveCapacity(count * 4)
        var normals   = [SIMD3<Float>](); normals.reserveCapacity(count * 4)
        var uvs       = [SIMD2<Float>](); uvs.reserveCapacity(count * 4)
        var indices   = [UInt32]();       indices.reserveCapacity(count * 6)

        let halfTile = fit.tileSize / 2
        let N        = Float(slotMap.slotCount)
        let up       = SIMD3<Float>(0, 1, 0)

        for (i, tile) in tiles.enumerated() {
            let base   = UInt32(i * 4)
            let center = fit.tileCenter(tileX: tile.tileX, tileZ: tile.tileZ)
            let cx = center.x, cz = center.z

            // 4 corners: NW(0), NE(1), SE(2), SW(3)
            // N = −Z edge, E = +X edge, S = +Z edge, W = −X edge
            positions.append(SIMD3<Float>(cx - halfTile, 0, cz - halfTile))  // NW
            positions.append(SIMD3<Float>(cx + halfTile, 0, cz - halfTile))  // NE
            positions.append(SIMD3<Float>(cx + halfTile, 0, cz + halfTile))  // SE
            positions.append(SIMD3<Float>(cx - halfTile, 0, cz + halfTile))  // SW
            normals.append(contentsOf: [up, up, up, up])

            // Atlas column UV for this tile's slot
            let s  = Float(slotMap.slot(for: tile.graphicIndex))
            let u0 = s / N, u1 = (s + 1) / N

            // NW(u0,0), NE(u1,0), SE(u1,1), SW(u0,1)
            // v=0 → UV top → Metal v=0 → image row 0 → top of tile art
            uvs.append(SIMD2<Float>(u0, 0)); uvs.append(SIMD2<Float>(u1, 0))
            uvs.append(SIMD2<Float>(u1, 1)); uvs.append(SIMD2<Float>(u0, 1))

            // Two CCW triangles from above (+Y).
            // cross((SE−NW),(NE−SE)) = cross((2,0,2),(0,0,−2)) = (0,+4,0) = +Y ✓
            // Order: NW→SE→NE then NW→SW→SE
            indices.append(contentsOf: [base, base+2, base+1,
                                        base, base+3, base+2])
        }

        return TabletopTerrainChunkGeometry(
            positions:          positions,
            normals:            normals,
            textureCoordinates: uvs,
            triangleIndices:    indices)
    }

    /// Builds a terrain-chunk mesh with per-tile relief: each tile's top quad
    /// is raised/recessed to its `height`, and a vertical "skirt" quad is
    /// emitted on any edge where the neighbouring tile is lower (or the map
    /// ends) so the elevation change shows a real, shaded edge instead of a
    /// seam.  This keeps the chunked, bounded-entity architecture (still one
    /// mesh per chunk) while giving the board visible 2.5D relief.
    ///
    /// - Parameters:
    ///   - tiles:      (tileX, tileZ, graphicIndex?, height) for each chunk tile.
    ///   - fit:        Board-space tile sizing and centering.
    ///   - slotMap:    Atlas layout — maps each graphicIndex to a UV column.
    ///   - heightAt:   Height of an arbitrary map tile (nil ⇒ outside the map).
    ///                 Used to decide where cliffs/skirts are needed.
    ///   - edgeFloorY: Skirt bottom used at the map boundary (typically the
    ///                 substrate top), so border tiles drop cleanly to the slab.
    public static func buildRelief(
        tiles:      [(tileX: Int, tileZ: Int, graphicIndex: Int?, height: Float)],
        fit:        TabletopMapFit,
        slotMap:    TabletopAtlasSlotMap,
        heightAt:   (Int, Int) -> Float?,
        edgeFloorY: Float
    ) -> TabletopTerrainChunkGeometry {
        var positions: [SIMD3<Float>] = []
        var normals:   [SIMD3<Float>] = []
        var uvs:       [SIMD2<Float>] = []
        var indices:   [UInt32]       = []

        let halfTile = fit.tileSize / 2
        let N        = Float(slotMap.slotCount)
        let up       = SIMD3<Float>(0, 1, 0)
        let eps: Float = 1e-5

        // Appends one quad from four corners with an explicit outward normal.
        // The triangle winding is auto-corrected so the geometric normal always
        // agrees with `normal` (front-facing under back-face culling).
        func addQuad(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>,
                     _ p2: SIMD3<Float>, _ p3: SIMD3<Float>,
                     normal: SIMD3<Float>,
                     _ uv0: SIMD2<Float>, _ uv1: SIMD2<Float>,
                     _ uv2: SIMD2<Float>, _ uv3: SIMD2<Float>) {
            let base = UInt32(positions.count)
            let geo = crossProduct(p1 - p0, p2 - p0)
            let flip = dot(geo, normal) < 0
            if flip {
                positions.append(contentsOf: [p0, p3, p2, p1])
                uvs.append(contentsOf: [uv0, uv3, uv2, uv1])
            } else {
                positions.append(contentsOf: [p0, p1, p2, p3])
                uvs.append(contentsOf: [uv0, uv1, uv2, uv3])
            }
            normals.append(contentsOf: [normal, normal, normal, normal])
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }

        for tile in tiles {
            let center = fit.tileCenter(tileX: tile.tileX, tileZ: tile.tileZ)
            let cx = center.x, cz = center.z
            let h  = tile.height
            let s  = Float(slotMap.slot(for: tile.graphicIndex))
            let u0 = s / N, u1 = (s + 1) / N

            // Top quad (raised/recessed to the tile height).
            let nw = SIMD3<Float>(cx - halfTile, h, cz - halfTile)
            let ne = SIMD3<Float>(cx + halfTile, h, cz - halfTile)
            let se = SIMD3<Float>(cx + halfTile, h, cz + halfTile)
            let sw = SIMD3<Float>(cx - halfTile, h, cz + halfTile)
            addQuad(nw, ne, se, sw, normal: up,
                    SIMD2<Float>(u0, 0), SIMD2<Float>(u1, 0),
                    SIMD2<Float>(u1, 1), SIMD2<Float>(u0, 1))

            // Side skirts wherever this tile stands above its neighbour (or the
            // map edge). The higher tile owns the cliff; equal-height neighbours
            // produce no skirt.
            func skirt(neighborX: Int, neighborZ: Int,
                       topA: SIMD3<Float>, topB: SIMD3<Float>,
                       outward: SIMD3<Float>) {
                let nh = heightAt(neighborX, neighborZ) ?? edgeFloorY
                guard nh < h - eps else { return }
                let botA = SIMD3<Float>(topA.x, nh, topA.z)
                let botB = SIMD3<Float>(topB.x, nh, topB.z)
                addQuad(topA, topB, botB, botA, normal: outward,
                        SIMD2<Float>(u0, 0), SIMD2<Float>(u1, 0),
                        SIMD2<Float>(u1, 1), SIMD2<Float>(u0, 1))
            }
            skirt(neighborX: tile.tileX, neighborZ: tile.tileZ - 1,
                  topA: nw, topB: ne, outward: SIMD3<Float>(0, 0, -1)) // North
            skirt(neighborX: tile.tileX + 1, neighborZ: tile.tileZ,
                  topA: ne, topB: se, outward: SIMD3<Float>(1, 0, 0))  // East
            skirt(neighborX: tile.tileX, neighborZ: tile.tileZ + 1,
                  topA: se, topB: sw, outward: SIMD3<Float>(0, 0, 1))  // South
            skirt(neighborX: tile.tileX - 1, neighborZ: tile.tileZ,
                  topA: sw, topB: nw, outward: SIMD3<Float>(-1, 0, 0)) // West
        }

        return TabletopTerrainChunkGeometry(
            positions:          positions,
            normals:            normals,
            textureCoordinates: uvs,
            triangleIndices:    indices)
    }

    /// Framework-free 3-vector cross product (avoids importing `simd`).
    static func crossProduct(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(a.y * b.z - a.z * b.y,
                     a.z * b.x - a.x * b.z,
                     a.x * b.y - a.y * b.x)
    }

    static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
