// TabletopMapFit.swift
//
// Pure geometry for fitting an arbitrary engine map (any width × height in
// tiles) onto the fixed physical tabletop board. The demo board assumed a
// fixed 7×7 grid; a real Wargus scenario is 32×32, 64×64, 96×96 or larger, so
// the board must rescale each tile to fit the full map into the same physical
// footprint the user places and manipulates.
//
// This computation is framework-free and unit-tested on the host Mac. The
// RealityKit layer (TabletopSceneBuilder / TabletopBoardView) consumes it to
// size and position terrain and unit entities.
import Foundation

/// Fits a `width × height` tile map into a square physical board of side
/// `boardExtent` meters, preserving square tiles and centering the map on the
/// board origin (0,0). The larger map dimension spans the full board extent;
/// the smaller dimension is centered with margin.
public struct TabletopMapFit: Equatable {
    public let width: Int
    public let height: Int
    public let boardExtent: Float

    public init(width: Int, height: Int, boardExtent: Float) {
        // Guard against degenerate maps so tileSize is always finite/positive.
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.boardExtent = boardExtent
    }

    /// Side length (meters) of one tile so the longer map axis exactly spans
    /// the board. Square tiles keep the map's aspect ratio undistorted.
    public var tileSize: Float {
        boardExtent / Float(max(width, height))
    }

    /// Board-local center (meters) of tile (tileX, tileZ), with the whole map
    /// centered on the board origin. tileX increases +X (east), tileZ
    /// increases +Z (south), matching the engine's row-major layout.
    public func tileCenter(tileX: Int, tileZ: Int) -> (x: Float, z: Float) {
        let ts = tileSize
        let originX = -Float(width - 1) / 2 * ts
        let originZ = -Float(height - 1) / 2 * ts
        return (originX + Float(tileX) * ts, originZ + Float(tileZ) * ts)
    }

    /// Shared tile-edge coordinates. Computing an edge from its integer grid
    /// coordinate makes the east edge of tile x bit-identical to the west edge
    /// of tile x+1, including across independently-built chunk meshes.
    public func tileBounds(
        tileX: Int, tileZ: Int
    ) -> (minX: Float, maxX: Float, minZ: Float, maxZ: Float) {
        let ts = tileSize
        let mapMinX = -Float(width) * ts / 2
        let mapMinZ = -Float(height) * ts / 2
        let minX = mapMinX + Float(tileX) * ts
        let minZ = mapMinZ + Float(tileZ) * ts
        return (minX, mapMinX + Float(tileX + 1) * ts,
                minZ, mapMinZ + Float(tileZ + 1) * ts)
    }

    /// Converts a board-local position back to the nearest tile coordinate.
    /// Used to translate a "tap empty tile" gesture into a move target.
    public func tile(atX x: Float, z: Float) -> (tileX: Int, tileZ: Int) {
        let ts = tileSize
        let originX = -Float(width - 1) / 2 * ts
        let originZ = -Float(height - 1) / 2 * ts
        let tx = Int(((x - originX) / ts).rounded())
        let tz = Int(((z - originZ) / ts).rounded())
        return (tx, tz)
    }

    /// True when (tileX, tileZ) is inside the map bounds.
    public func contains(tileX: Int, tileZ: Int) -> Bool {
        tileX >= 0 && tileX < width && tileZ >= 0 && tileZ < height
    }

    /// Rendered edge length for a single tile quad, slightly inset so adjacent
    /// tiles show a thin seam (matches the demo board's 0.96 inset).
    public var tileQuadSize: Float { tileSize * 0.96 }
}

/// Pure geometry for a unit type's tile footprint (ABI v4). Framework-free so
/// the centring math is host-testable. A building's engine `tilePos` is its
/// north-west corner; this yields the offset to the footprint's geometric
/// centre so a multi-tile building renders centred on the tiles it covers.
public enum TabletopFootprint {
    /// The tile-space offset from a footprint's NW-corner tile to its geometric
    /// centre. A 1×1 unit has a zero offset; a 3×3 building's centre sits 1 tile
    /// in on each axis; a 2×2 building's centre sits half a tile in.
    public static func centerOffsetTiles(width: Int, height: Int) -> (dx: Double, dz: Double) {
        (Double(max(1, width) - 1) / 2.0, Double(max(1, height) - 1) / 2.0)
    }
}
