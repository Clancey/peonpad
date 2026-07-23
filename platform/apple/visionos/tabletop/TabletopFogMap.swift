// TabletopFogMap.swift
//
// Framework-free fog-of-war pixel-buffer state for the visionOS tabletop board.
// Uses CoreGraphics only for cgImage() so tests compile on the host Mac without
// a Simulator.  The pixel buffer feeds a single full-board fog-overlay texture,
// replacing one ModelEntity per tile with one entity for the entire map.
//
// Pixel layout:
//   - Row-major, row 0 = tileZ = 0 (north/−Z edge, UV v = 0 in Metal).
//   - Column x = tileX, column x+1 = tileX+1.
//   - Per tile: one of three canonical fog states drives the overlay alpha:
//       unexplored → opaque dark shroud, explored → dim translucent veil,
//       visible    → fully clear (no veil, terrain shows through).
import CoreGraphics
import Foundation

/// Fog-of-war state for the entire map as a per-tile three-state grid.
/// One cell per tile; updating a tile is a single write. `cgImage()` bakes the
/// grid into an RGBA texture (one texel per tile) for a single board-covering
/// entity, so fog updates re-upload a texture rather than toggling geometry.
public struct TabletopFogMap {

    public let mapWidth:  Int
    public let mapHeight: Int

    /// Fog veil colour (dark charcoal). The alpha per tile comes from its state.
    public static let fogR: UInt8 = 16
    public static let fogG: UInt8 = 16
    public static let fogB: UInt8 = 16

    /// Opaque shroud over never-explored tiles (~88 % — matches the old overlay).
    public static let unexploredAlpha: UInt8 = 224
    /// Dim translucent veil over explored-but-not-currently-visible tiles.
    public static let exploredAlpha: UInt8 = 140
    /// Currently-visible tiles carry no veil.
    public static let visibleAlpha: UInt8 = 0
    /// Retained name for the opaque-shroud alpha (binary callers/tests).
    public static var fogAlpha: UInt8 { unexploredAlpha }

    /// The alpha byte a given visibility renders with.
    public static func alpha(for visibility: TabletopFogVisibility) -> UInt8 {
        switch visibility {
        case .unexplored: return unexploredAlpha
        case .explored:   return exploredAlpha
        case .visible:    return visibleAlpha
        }
    }

    // Flat per-tile state grid: index = tileZ * mapWidth + tileX.
    private var states: [TabletopFogVisibility]

    // MARK: - Init

    /// Creates a fully-unexplored (opaque) map of the given dimensions.
    public init(mapWidth: Int, mapHeight: Int) {
        let w = max(1, mapWidth)
        let h = max(1, mapHeight)
        self.mapWidth  = w
        self.mapHeight = h
        self.states = [TabletopFogVisibility](repeating: .unexplored, count: w * h)
    }

    @inline(__always)
    private func index(_ tileX: Int, _ tileZ: Int) -> Int? {
        guard tileX >= 0, tileX < mapWidth, tileZ >= 0, tileZ < mapHeight else { return nil }
        return tileZ * mapWidth + tileX
    }

    // MARK: - Mutation

    /// Sets the full three-state visibility of tile (tileX, tileZ). Out-of-bounds
    /// tiles are silently ignored.
    public mutating func setVisibility(_ visibility: TabletopFogVisibility, tileX: Int, tileZ: Int) {
        guard let i = index(tileX, tileZ) else { return }
        states[i] = visibility
    }

    /// Binary-compatible reveal: `true` → `.visible`, `false` → `.unexplored`.
    /// Prefer `setVisibility` to preserve the explored (dim) state.
    public mutating func setRevealed(_ revealed: Bool, tileX: Int, tileZ: Int) {
        setVisibility(revealed ? .visible : .unexplored, tileX: tileX, tileZ: tileZ)
    }

    // MARK: - Query

    /// The three-state visibility of tile (tileX, tileZ); off-map → `.unexplored`.
    public func visibility(tileX: Int, tileZ: Int) -> TabletopFogVisibility {
        guard let i = index(tileX, tileZ) else { return .unexplored }
        return states[i]
    }

    /// Whether tile (tileX, tileZ) is explored or visible (i.e. not a shroud).
    public func isRevealed(tileX: Int, tileZ: Int) -> Bool {
        visibility(tileX: tileX, tileZ: tileZ) != .unexplored
    }

    /// Number of revealed (explored or visible) tiles — instrumentation / tests.
    public var revealedCount: Int { states.lazy.filter { $0 != .unexplored }.count }
    /// Number of currently-visible tiles.
    public var visibleCount: Int { states.lazy.filter { $0 == .visible }.count }
    /// Number of explored-but-not-visible tiles.
    public var exploredCount: Int { states.lazy.filter { $0 == .explored }.count }
    /// Number of never-explored (shrouded) tiles.
    public var unexploredCount: Int { states.lazy.filter { $0 == .unexplored }.count }

    // MARK: - CGImage

    /// Creates a `CGImage` from the current fog state for use as a
    /// `TextureResource` in RealityKit. Row 0 of the image = tileZ = 0,
    /// which maps to Metal UV v = 0 = the north (−Z) edge of the board plane.
    /// RGB is premultiplied by the per-tile alpha (premultipliedLast) so the
    /// veil composites without a dark halo at the visible/explored boundary.
    /// Returns `nil` on any CoreGraphics failure (caller keeps the old texture).
    public func cgImage() -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: mapWidth * mapHeight * 4)
        for i in 0..<(mapWidth * mapHeight) {
            let a = Int(Self.alpha(for: states[i]))
            pixels[i*4 + 0] = UInt8(Int(Self.fogR) * a / 255)
            pixels[i*4 + 1] = UInt8(Int(Self.fogG) * a / 255)
            pixels[i*4 + 2] = UInt8(Int(Self.fogB) * a / 255)
            pixels[i*4 + 3] = UInt8(a)
        }
        let data = Data(pixels)   // owned copy: retained by the CGDataProvider
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width:             mapWidth,
            height:            mapHeight,
            bitsPerComponent:  8,
            bitsPerPixel:      32,
            bytesPerRow:       mapWidth * 4,
            space:             colorSpace,
            bitmapInfo:        bitmapInfo,
            provider:          provider,
            decode:            nil,
            shouldInterpolate: false,
            intent:            .defaultIntent
        )
    }
}
