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
//   - RGBA: R/G/B = fogColor, A = 0 (revealed) | fogAlpha (fogged).
//   - Alpha = 0 → fully transparent (revealed tile shows terrain beneath).
//   - Alpha = fogAlpha → dark opaque overlay (unrevealed tile).
import CoreGraphics
import Foundation

/// Fog-of-war state for the entire map as a flat RGBA pixel buffer.
/// One pixel per tile; updating a tile is a single byte write.
/// The buffer drives a `TextureResource` on a single board-covering entity.
public struct TabletopFogMap {

    public let mapWidth:  Int
    public let mapHeight: Int

    /// Fog RGBA (dark, ~88 % opaque — visually matches the old per-tile overlay).
    public static let fogR:     UInt8 = 16
    public static let fogG:     UInt8 = 16
    public static let fogB:     UInt8 = 16
    public static let fogAlpha: UInt8 = 224

    // Flat RGBA buffer: index = (tileZ * mapWidth + tileX) * 4
    private var pixels: [UInt8]

    // MARK: - Init

    /// Creates a fully-fogged map of the given dimensions.
    public init(mapWidth: Int, mapHeight: Int) {
        let w = max(1, mapWidth)
        let h = max(1, mapHeight)
        self.mapWidth  = w
        self.mapHeight = h
        self.pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i*4 + 0] = Self.fogR
            pixels[i*4 + 1] = Self.fogG
            pixels[i*4 + 2] = Self.fogB
            pixels[i*4 + 3] = Self.fogAlpha
        }
    }

    // MARK: - Mutation

    /// Sets the revealed state of tile (tileX, tileZ). Out-of-bounds tiles are
    /// silently ignored.
    public mutating func setRevealed(_ revealed: Bool, tileX: Int, tileZ: Int) {
        guard tileX >= 0, tileX < mapWidth,
              tileZ >= 0, tileZ < mapHeight else { return }
        pixels[(tileZ * mapWidth + tileX) * 4 + 3] = revealed ? 0 : Self.fogAlpha
    }

    // MARK: - Query

    /// Whether tile (tileX, tileZ) is currently revealed.
    public func isRevealed(tileX: Int, tileZ: Int) -> Bool {
        guard tileX >= 0, tileX < mapWidth,
              tileZ >= 0, tileZ < mapHeight else { return false }
        return pixels[(tileZ * mapWidth + tileX) * 4 + 3] == 0
    }

    /// Number of currently revealed tiles (useful for instrumentation / tests).
    public var revealedCount: Int {
        var n = 0
        for i in 0..<(mapWidth * mapHeight) {
            if pixels[i*4 + 3] == 0 { n += 1 }
        }
        return n
    }

    // MARK: - CGImage

    /// Creates a `CGImage` from the current fog state for use as a
    /// `TextureResource` in RealityKit. Row 0 of the image = tileZ = 0,
    /// which maps to Metal UV v = 0 = the north (−Z) edge of the board plane.
    /// Returns `nil` on any CoreGraphics failure (caller keeps the old texture).
    public func cgImage() -> CGImage? {
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
