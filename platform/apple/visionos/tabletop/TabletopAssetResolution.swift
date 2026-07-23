// TabletopAssetResolution.swift
//
// Pure, framework-free logic for turning engine-owned art descriptors (the
// ABI v3 tileset + unit sprite metadata carried on a snapshot) into concrete
// "load this rectangle of this staged image, mirrored/tinted like so" requests,
// plus the supporting geometry, path-confinement, team-color, and bounded-cache
// primitives.
//
// This is the production asset-resolution brain. It never touches RealityKit,
// UIKit, or the filesystem itself — the app-only `WargusTabletopMaterialProvider`
// consumes these placements to decode staged PNGs and build materials. Keeping
// the decision logic here means path confinement, source-rectangle math, team
// tinting, direction/frame selection, and cache eviction are all unit-tested on
// the host Mac without a Simulator or any proprietary asset.
//
// Nothing in this file imports SwiftUI, RealityKit, UIKit, or C interop.
import Foundation

// MARK: - Source rectangle

/// A pixel rectangle within a decoded image, used to crop a single tile or
/// sprite frame out of an atlas/sheet.
public struct TabletopSourceRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Team color

/// A normalized (0...1) RGBA team tint, derived deterministically from a
/// player/owner index. Applied by the material provider to the team-colored
/// region of a sprite (an approximation of the engine's palette remap when the
/// provider cannot recover the sprite's original palette indices).
public struct TabletopTeamTint: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Maps a player/owner index to a stable team tint following Warcraft II's
/// canonical player-color ordering. Deterministic and framework-free so the
/// team-color behavior is unit-testable; the RGB values are generic primary
/// colors (no proprietary palette data is embedded).
public enum TabletopTeamPalette {
    /// Canonical eight-player tints (0...7); indices wrap for higher indices.
    public static let tints: [TabletopTeamTint] = [
        TabletopTeamTint(red: 0.80, green: 0.10, blue: 0.10), // 0 red
        TabletopTeamTint(red: 0.13, green: 0.30, blue: 0.85), // 1 blue
        TabletopTeamTint(red: 0.10, green: 0.65, blue: 0.55), // 2 teal
        TabletopTeamTint(red: 0.50, green: 0.15, blue: 0.65), // 3 violet
        TabletopTeamTint(red: 0.90, green: 0.55, blue: 0.10), // 4 orange
        TabletopTeamTint(red: 0.12, green: 0.12, blue: 0.14), // 5 black
        TabletopTeamTint(red: 0.90, green: 0.90, blue: 0.90), // 6 white
        TabletopTeamTint(red: 0.20, green: 0.65, blue: 0.20), // 7 green
    ]

    /// The team tint for a player/owner index (wraps for indices ≥ 8, clamps
    /// negatives to 0).
    public static func tint(owner: Int) -> TabletopTeamTint {
        let count = tints.count
        let idx = ((owner % count) + count) % count
        return tints[idx]
    }
}

// MARK: - Atlas geometry

/// Pure grid math for locating one tile/sprite frame inside a fixed-cell atlas.
public enum TabletopAtlasGeometry {
    /// The source rectangle for `frame` in an image whose cells are
    /// `frameWidth × frameHeight`, laid out left-to-right, top-to-bottom, using
    /// the decoded image's pixel width to compute the column count.
    ///
    /// Returns `nil` for degenerate inputs (non-positive frame/image size, a
    /// frame that falls outside the image), so the caller can fall back to
    /// procedural content rather than crop garbage.
    public static func sourceRect(
        frame: Int,
        frameWidth: Int,
        frameHeight: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> TabletopSourceRect? {
        guard frame >= 0,
              frameWidth > 0, frameHeight > 0,
              imageWidth >= frameWidth, imageHeight >= frameHeight
        else { return nil }
        let columns = imageWidth / frameWidth
        guard columns > 0 else { return nil }
        let col = frame % columns
        let row = frame / columns
        let x = col * frameWidth
        let y = row * frameHeight
        guard x + frameWidth <= imageWidth,
              y + frameHeight <= imageHeight
        else { return nil }
        return TabletopSourceRect(x: x, y: y, width: frameWidth, height: frameHeight)
    }
}

// MARK: - Path confinement

/// Confines a relative asset path to the staged read-only game-data root,
/// rejecting anything that could escape it (absolute paths, `..` traversal,
/// embedded NULs, or Windows-style separators). Returns the normalized
/// forward-slash relative path, or `nil` when the path is unsafe/empty.
public enum TabletopAssetPath {
    /// The engine writes its expanded/generated tileset PNG cache under this
    /// fixed subdirectory (see PeonPadTabletopBridge.cpp's
    /// ExportExpandedTilesetPNG / TabletopTilesetExportRelativePath), always
    /// under the writable user/cache root — never the read-only staged data
    /// root. This constant documents that engine-side filename convention
    /// for reference only; which root a placement resolves against is
    /// decided from the explicit `TabletopTilesetInfo.pathRoot` /
    /// `PeonPadTilesetPathRoot` ABI v5 discriminator (see
    /// `WargusStagedAssetResolver.terrainPlacement`), never by sniffing this
    /// prefix — a future rename/relocation of the engine's convention would
    /// otherwise silently break placement resolution.
    public static let generatedCachePrefix = "tabletop-generated/"

    public static func confine(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard !raw.contains("\0") else { return nil }
        guard !raw.contains("\\") else { return nil }
        // Absolute paths escape the root.
        guard !raw.hasPrefix("/") else { return nil }
        // Normalize and reject any traversal or empty segment weirdness.
        var segments: [String] = []
        for segment in raw.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(segment)
            if s == "." { continue }
            if s == ".." { return nil }
            segments.append(s)
        }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: "/")
    }

    /// Resolves a confined relative path against a root directory URL. Returns
    /// `nil` when confinement fails or the resolved path escapes `root`.
    public static func resolvedURL(root: URL, relative: String) -> URL? {
        guard let confined = confine(relative) else { return nil }
        let url = root.appendingPathComponent(confined).standardizedFileURL
        let base = root.standardizedFileURL.path
        // Ensure the resolved path is still within the root (defense in depth).
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard url.path == base || url.path.hasPrefix(prefix) else { return nil }
        return url
    }
}

// MARK: - Placement

/// A concrete instruction for the material provider: crop `sourceRect` (or the
/// whole image when `sourceRect == nil`) out of the staged image at
/// `relativePath`, optionally mirror it horizontally, and tint its team region.
public struct TabletopAssetPlacement: Equatable, Sendable {
    /// Confined path relative to the staged game-data root (or, when
    /// `isGeneratedCache` is true, relative to the writable user/cache root
    /// instead — see `TabletopAssetPath.generatedCachePrefix`).
    public var relativePath: String
    /// The frame/graphic index within the atlas (informational; the provider
    /// computes `sourceRect` once it knows the decoded image dimensions).
    public var frame: Int
    /// Cell size in pixels; `0` means "use the whole image" (no atlas grid).
    public var cellWidth: Int
    public var cellHeight: Int
    /// Whether to draw the cropped frame horizontally mirrored.
    public var mirror: Bool
    /// Team tint for the sprite's team-colored region, or `nil` for terrain and
    /// team-less content.
    public var teamTint: TabletopTeamTint?
    /// True when `relativePath` names a file the *engine* generated at
    /// runtime (e.g. the fully-expanded tileset PNG — see
    /// PeonPadTabletopBridge.cpp's ExportExpandedTilesetPNG) rather than an
    /// authored asset staged from the read-only game-data root. The engine
    /// never writes into that read-only root (see EngineStartupPlan.swift),
    /// so generated files live under a separate writable user/cache root;
    /// the material provider resolves this placement against that root
    /// instead of `dataRoot`.
    public var isGeneratedCache: Bool
    public init(
        relativePath: String,
        frame: Int = 0,
        cellWidth: Int = 0,
        cellHeight: Int = 0,
        mirror: Bool = false,
        teamTint: TabletopTeamTint? = nil,
        isGeneratedCache: Bool = false
    ) {
        self.relativePath = relativePath
        self.frame = frame
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.mirror = mirror
        self.teamTint = teamTint
        self.isGeneratedCache = isGeneratedCache
    }

    /// The source rectangle for this placement given a decoded image's pixel
    /// dimensions, or `nil` to use the whole image (no atlas grid) / on
    /// degenerate geometry.
    public func sourceRect(imageWidth: Int, imageHeight: Int) -> TabletopSourceRect? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        return TabletopAtlasGeometry.sourceRect(
            frame: frame,
            frameWidth: cellWidth, frameHeight: cellHeight,
            imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// A stable cache key for a decoded, cropped, mirrored, tinted result.
    /// A stable cache key for a decoded, cropped, mirrored, tinted result.
    /// Includes `isGeneratedCache` (the root discriminator) so the *same*
    /// relative path under the data root vs. the cache root — which the
    /// LRU cache and in-flight `pending` dictionary key on this string —
    /// never alias: without it, a tileset transition that toggles only the
    /// root (not the path text) could serve a completed data-root decode (or
    /// coalesce onto an in-flight data-root request) for a placement that
    /// actually needs the cache-root file, even though the chunk-level
    /// generation guard is otherwise correct.
    public var cacheKey: String {
        let tint = teamTint.map { "\($0.red),\($0.green),\($0.blue),\($0.alpha)" } ?? "-"
        return "\(relativePath)#f\(frame)#c\(cellWidth)x\(cellHeight)#m\(mirror ? 1 : 0)"
            + "#r\(isGeneratedCache ? 1 : 0)#t\(tint)"
    }
}

// MARK: - Production staged-data resolver

/// Resolves engine-owned art descriptors into staged-data placements. Pure and
/// framework-free: it only decides *what* to load (a confined relative path,
/// atlas frame, mirror, and team tint). The app-only material provider performs
/// the actual decode/crop/tint/material creation.
///
/// A placement is returned only when the descriptor names a real, confinable
/// asset path; otherwise `nil` drives a per-asset procedural fallback (never a
/// silent whole-app demo fallback).
public final class WargusStagedAssetResolver: @unchecked Sendable {
    public init() {}

    /// Placement for a terrain tile, or `nil` when the snapshot carries no
    /// tileset / an unconfinable path (procedural color fallback for that tile).
    public func terrainPlacement(
        graphicIndex: Int?,
        tileset: TabletopTilesetInfo?
    ) -> TabletopAssetPlacement? {
        guard let tileset,
              let graphicIndex,
              graphicIndex >= 0,
              tileset.pixelTileWidth > 0,
              tileset.pixelTileHeight > 0,
              let path = TabletopAssetPath.confine(tileset.imagePath)
        else { return nil }
        return TabletopAssetPlacement(
            relativePath: path,
            frame: graphicIndex,
            cellWidth: tileset.pixelTileWidth,
            cellHeight: tileset.pixelTileHeight,
            mirror: false,
            teamTint: nil,
            isGeneratedCache: tileset.pathRoot == .cacheRoot)
    }

    /// Placement for a unit's current sprite frame, or `nil` when the unit has
    /// no sprite descriptor / an unconfinable path (procedural billboard
    /// fallback for that unit).
    ///
    /// `frameOverride`/`mirrorOverride` let the per-frame billboard pass supply
    /// a *camera-relative* directional frame (see `TabletopSpriteDirection`)
    /// instead of the engine's map-relative one; when `nil` the unit's own
    /// engine-resolved frame/mirror are used.
    public func unitPlacement(
        unit: TabletopGameplayUnit,
        sprite: TabletopUnitSpriteInfo?,
        frameOverride: Int? = nil,
        mirrorOverride: Bool? = nil
    ) -> TabletopAssetPlacement? {
        guard let sprite,
              sprite.frameWidth > 0,
              sprite.frameHeight > 0,
              let path = TabletopAssetPath.confine(sprite.spritePath)
        else { return nil }
        let frame = max(0, frameOverride ?? unit.spriteFrame ?? 0)
        let mirror = mirrorOverride ?? unit.spriteMirror ?? false
        let teamTint = sprite.teamColorCount > 0
            ? TabletopTeamPalette.tint(owner: unit.owner)
            : nil
        return TabletopAssetPlacement(
            relativePath: path,
            frame: frame,
            cellWidth: sprite.frameWidth,
            cellHeight: sprite.frameHeight,
            mirror: mirror,
            teamTint: teamTint)
    }
}

// MARK: - Bounded LRU cache

/// A small, deterministic least-recently-used cache with a fixed capacity,
/// used by the material provider to bound decoded-texture memory for one loaded
/// scenario. Pure and framework-free so eviction order is unit-testable; the
/// provider wraps it with main-actor-safe RealityKit texture values.
public final class TabletopLRUCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []          // most-recently-used at the end
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { storage.count }

    /// The current key order, least-recently-used first. Exposed for testing.
    public var keysByRecency: [Key] { order }

    /// Returns the value for `key`, marking it most-recently-used.
    public func value(forKey key: Key) -> Value? {
        guard let v = storage[key] else { return nil }
        touch(key)
        return v
    }

    /// Inserts/updates `key`, marking it most-recently-used and evicting the
    /// least-recently-used entry when over capacity. Returns the evicted value
    /// (if any) so the caller can release associated resources.
    @discardableResult
    public func setValue(_ value: Value, forKey key: Key) -> Value? {
        if storage[key] != nil {
            storage[key] = value
            touch(key)
            return nil
        }
        storage[key] = value
        order.append(key)
        if storage.count > capacity {
            let evictKey = order.removeFirst()
            let evicted = storage.removeValue(forKey: evictKey)
            return evicted
        }
        return nil
    }

    public func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private func touch(_ key: Key) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
    }
}
