// TabletopBoardLayers.swift
//
// Framework-free description of the tabletop's 2.5D layer hierarchy: the
// board-local elevations each surface lives on, the geometry of the thick
// board substrate/frame slab that sits *below* the terrain to give the board
// visible depth, and the readiness/stale-completion helpers that keep the
// board stable while real-art atlases stream in.
//
// Nothing here imports RealityKit or UIKit — only `Foundation` (which brings
// the `SIMD*` types).  The RealityKit layer (TabletopChunkBoard) turns the
// geometry below into `MeshResource`/`ModelEntity` values, but the elevation
// math and slab vertices are all deterministic and host-testable with a plain
// `swiftc` invocation:
//
//   ./scripts/test-visionos-tabletop-layers.sh
import Foundation
import simd

// MARK: - Layer elevations

/// The board-local Y elevation of each 2.5D layer.  Kept deliberately apart so
/// no two rendered surfaces are ever coplanar — coplanar opaque/transparent
/// planes are the classic source of depth-buffer flicker ("z-fighting"), which
/// is exactly what the old fog-at-0.005-above-terrain-at-0 layout produced.
///
/// Ordering (low → high):  substrate bottom < substrate top < terrain < fog.
public enum TabletopBoardElevation {

    /// Terrain surface plane.  Unit billboards' feet rest here.
    public static let terrainSurfaceY: Float = 0.0

    /// Top face of the board substrate/frame slab.  Sits just *below* the
    /// terrain so the terrain reads as the tabletop surface resting on a solid
    /// slab, and the two planes are never coplanar.
    public static let substrateTopY: Float = -0.004

    /// Bottom face of the substrate slab.  The gap to `substrateTopY` gives the
    /// board a visible ~4.6 cm thickness so it reads as a physical 2.5D board
    /// rather than a flat decal.
    public static let substrateBottomY: Float = -0.05

    /// Fog-of-war / effects elevation.  Clearly above the terrain so the fog
    /// veil and the terrain surface are never coplanar (the previous 5 mm gap
    /// combined a transparent overlay with the opaque terrain plane).
    public static let fogY: Float = 0.008

    /// Meters the substrate frame extends beyond the terrain area on every
    /// side, so the slab reads as a framed board with a visible rim.
    public static let frameBorder: Float = 0.03

    /// Solid thickness of the substrate slab (always > 0).
    public static var substrateThickness: Float { substrateTopY - substrateBottomY }

    /// The distinct layer elevations, low → high.  Exposed so tests can assert
    /// strict separation (no coplanar layers).
    public static var orderedElevations: [Float] {
        [substrateBottomY, substrateTopY, terrainSurfaceY, fogY]
    }
}

// MARK: - Shared mesh data

/// Flat vertex arrays for one RealityKit mesh, framework-free so the geometry
/// can be built and asserted on the host.  Mirrors the shape of
/// `TabletopTerrainChunkGeometry`; the RealityKit layer adds a `meshDescriptor`
/// bridge for it.
public struct TabletopBoardMeshData: Equatable {
    public let positions:          [SIMD3<Float>]
    public let normals:            [SIMD3<Float>]
    public let textureCoordinates: [SIMD2<Float>]
    public let triangleIndices:    [UInt32]

    public var isEmpty: Bool { triangleIndices.isEmpty }
}

// MARK: - Substrate slab layout

/// Computes the physical footprint of the substrate slab from a map fit.
public enum TabletopSubstrateLayout {

    /// The terrain area's rendered extent (meters) for a `mapWidth × mapHeight`
    /// map under `fit` — i.e. the XZ span the terrain chunks cover.
    public static func terrainExtent(
        fit: TabletopMapFit, mapWidth: Int, mapHeight: Int
    ) -> (width: Float, depth: Float) {
        (Float(max(mapWidth, 1)) * fit.tileSize,
         Float(max(mapHeight, 1)) * fit.tileSize)
    }

    /// The substrate slab's outer extent (meters): the terrain area plus a
    /// `frameBorder` rim on every side.
    public static func substrateExtent(
        fit: TabletopMapFit, mapWidth: Int, mapHeight: Int,
        frameBorder: Float = TabletopBoardElevation.frameBorder
    ) -> (width: Float, depth: Float) {
        let terrain = terrainExtent(fit: fit, mapWidth: mapWidth, mapHeight: mapHeight)
        return (terrain.width + 2 * frameBorder, terrain.depth + 2 * frameBorder)
    }
}

// MARK: - Substrate slab geometry

/// Builds the six-faced box mesh for the board substrate slab.  All faces have
/// outward normals and counter-clockwise (front-facing) winding, matching the
/// terrain chunks' CCW-from-above convention, so the slab is visible from any
/// angle around the board.
public enum TabletopSubstrateMeshBuilder {

    /// Builds a solid slab centered on the board origin (0,0) spanning
    /// `width × depth` in XZ and `[bottomY, topY]` in Y.
    public static func build(
        width:   Float,
        depth:   Float,
        topY:    Float = TabletopBoardElevation.substrateTopY,
        bottomY: Float = TabletopBoardElevation.substrateBottomY
    ) -> TabletopBoardMeshData {
        let hw = max(width, 0.0001) / 2
        let hd = max(depth, 0.0001) / 2
        let x0 = -hw, x1 = hw
        let z0 = -hd, z1 = hd
        // Guarantee a positive-thickness slab even if constants are mis-set.
        let y0 = min(bottomY, topY)
        let y1 = max(bottomY, topY) == min(bottomY, topY) ? min(bottomY, topY) + 0.001 : max(bottomY, topY)

        var positions: [SIMD3<Float>] = []
        var normals:   [SIMD3<Float>] = []
        var uvs:       [SIMD2<Float>] = []
        var indices:   [UInt32]       = []
        positions.reserveCapacity(24)
        normals.reserveCapacity(24)
        uvs.reserveCapacity(24)
        indices.reserveCapacity(36)

        // Emits one quad as two CCW triangles.  `u × v` points along the
        // outward face normal, so corners (c, c+u, c+u+v, c+v) are front-facing.
        func addQuad(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>) {
            let base = UInt32(positions.count)
            let n = normalize(cross(u, v))
            positions.append(c)
            positions.append(c + u)
            positions.append(c + u + v)
            positions.append(c + v)
            normals.append(contentsOf: [n, n, n, n])
            uvs.append(SIMD2<Float>(0, 0))
            uvs.append(SIMD2<Float>(1, 0))
            uvs.append(SIMD2<Float>(1, 1))
            uvs.append(SIMD2<Float>(0, 1))
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }

        let dx = SIMD3<Float>(x1 - x0, 0, 0)
        let dy = SIMD3<Float>(0, y1 - y0, 0)
        let dz = SIMD3<Float>(0, 0, z1 - z0)

        // Top (+Y)
        addQuad(SIMD3<Float>(x0, y1, z0), dz, dx)
        // Bottom (−Y)
        addQuad(SIMD3<Float>(x0, y0, z0), dx, dz)
        // South (+Z)
        addQuad(SIMD3<Float>(x0, y0, z1), dx, dy)
        // North (−Z)
        addQuad(SIMD3<Float>(x0, y0, z0), dy, dx)
        // East (+X)
        addQuad(SIMD3<Float>(x1, y0, z0), dy, dz)
        // West (−X)
        addQuad(SIMD3<Float>(x0, y0, z0), dz, dy)

        return TabletopBoardMeshData(
            positions:          positions,
            normals:            normals,
            textureCoordinates: uvs,
            triangleIndices:    indices)
    }
}

// MARK: - Board readiness

/// A snapshot of the board's real-art streaming progress, used to expose a
/// stable "all atlases settled" state to callers/tests without touching
/// RealityKit.  The board is "stable-ready" once every terrain chunk has
/// upgraded from its procedural placeholder to a real decoded atlas.
public struct TabletopBoardReadiness: Equatable {
    public let totalChunks:     Int
    public let atlasReadyCount: Int

    public init(totalChunks: Int, atlasReadyCount: Int) {
        self.totalChunks     = max(0, totalChunks)
        self.atlasReadyCount = max(0, atlasReadyCount)
    }

    /// True once every chunk has a real atlas applied.
    public var isStable: Bool {
        totalChunks > 0 && atlasReadyCount >= totalChunks
    }

    /// Fraction of chunks that have upgraded to real art, in [0, 1].
    public var fraction: Double {
        guard totalChunks > 0 else { return 0 }
        return min(1, Double(atlasReadyCount) / Double(totalChunks))
    }
}

/// Decides whether an asynchronously-decoded atlas completion is still valid
/// for the chunk it targets.  A chunk's generation is bumped every time it is
/// (re)built; a completion that captured an older generation is stale (a newer
/// rebuild has superseded it) and must be dropped to avoid overwriting current
/// art with an outdated texture — a source of flicker.
public enum TabletopAtlasCompletionGate {
    public static func accepts(requestGeneration: Int, currentGeneration: Int) -> Bool {
        requestGeneration == currentGeneration
    }
}
