// WargusTabletopMaterialProvider.swift
//
// The production, app-only bridge between the framework-free asset-resolution
// layer (TabletopAssetResolution.swift) and RealityKit. It turns engine-owned
// art descriptors into real `UnlitMaterial`s by:
//   • asking the pure `WargusStagedAssetResolver` for a confined placement,
//   • decoding the staged PNG off the main actor (never a per-frame disk read),
//   • cropping the atlas frame, baking any horizontal mirror, and applying a
//     team tint,
//   • creating the `TextureResource`/`UnlitMaterial` on the main actor
//     (RealityKit resource creation is main-actor bound),
//   • caching the result in a bounded LRU so memory stays bounded for one
//     loaded scenario and identical frames never re-decode.
//
// Every failure is per-asset: the completion simply never fires with a real
// material, so the caller keeps its procedural fallback for that one tile/unit
// — never a silent whole-app demo fallback. No proprietary art is bundled; all
// pixels come from the staged read-only data directory at runtime.
import Foundation
import RealityKit
import UIKit

@MainActor
public final class WargusTabletopMaterialProvider {
    /// The staged read-only game-data root (e.g. <container>/Documents/wargus-data).
    private let dataRoot: URL
    /// The writable user/cache root (e.g. <container>/.../user), or `nil` when
    /// unavailable. Engine-generated assets (see `TabletopAssetPlacement.
    /// isGeneratedCache`) resolve here instead of `dataRoot`, since the engine
    /// documents `dataRoot` as read-only and never writes into it.
    private let cacheRoot: URL?
    private let resolver = WargusStagedAssetResolver()
    /// Bounded decoded-material cache keyed by `TabletopAssetPlacement.cacheKey`.
    private let cache: TabletopLRUCache<String, UnlitMaterial>
    /// Pending completions per in-flight decode, keyed by cache key. Coalesces
    /// duplicate requests for the same placement (e.g. every grass tile sharing
    /// one graphic index) so a single decode serves *all* waiting callers rather
    /// than only the first — otherwise repeated tiles/sprites would stay
    /// procedural forever.
    private var pending: [String: [(UnlitMaterial) -> Void]] = [:]
    /// Serial background queue for file I/O + pixel work, off the main actor.
    private let decodeQueue = DispatchQueue(
        label: "org.peonpad.visionos.tabletop.assetdecode", qos: .userInitiated)

    public init(dataRoot: URL, cacheRoot: URL? = nil, cacheCapacity: Int = 512) {
        self.dataRoot = dataRoot
        self.cacheRoot = cacheRoot
        self.cache = TabletopLRUCache(capacity: cacheCapacity)
    }

    /// Builds a provider rooted at the staged data directory, or `nil` when it
    /// does not exist (the board then renders fully procedurally — an explicit,
    /// per-app absence, not a silent fallback masking a broken pipeline).
    ///
    /// `cachePath` is the writable user/cache directory (see
    /// `EngineLaunchConfig.userPath`) the engine writes its generated tileset
    /// PNG cache into. Unlike `dataPath` (which must already be fully staged
    /// before the engine can launch), `cachePath`'s "tabletop-generated/"
    /// subdirectory is created lazily by the engine at runtime — often after
    /// this provider is constructed — so its existence is deliberately *not*
    /// checked up front; an absent or not-yet-populated cache directory
    /// simply fails the later per-asset decode (as any missing asset does),
    /// keeping that one tile/sprite's procedural fallback rather than
    /// permanently disabling generated-cache resolution due to a race.
    public static func make(
        dataPath: String,
        cachePath: String? = nil,
        fileManager: FileManager = .default
    ) -> WargusTabletopMaterialProvider? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dataPath, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        let cacheRoot: URL? = cachePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return WargusTabletopMaterialProvider(
            dataRoot: URL(fileURLWithPath: dataPath, isDirectory: true),
            cacheRoot: cacheRoot)
    }

    /// The root a placement should be resolved against: `cacheRoot` (falling
    /// back to `dataRoot` if unavailable) for engine-generated assets,
    /// `dataRoot` for everything else. Authored-asset confinement is
    /// unaffected — `TabletopAssetPath.confine`/`resolvedURL` apply identically
    /// to either root.
    private func root(for placement: TabletopAssetPlacement) -> URL {
        placement.isGeneratedCache ? (cacheRoot ?? dataRoot) : dataRoot
    }

    // MARK: - Public requests

    /// Requests the real terrain-tile material for a snapshot terrain tile.
    /// `completion` fires (on the main actor) only when a real material is
    /// available; otherwise the caller keeps its procedural color.
    public func terrainMaterial(
        graphicIndex: Int?,
        tileset: TabletopTilesetInfo?,
        completion: @escaping (UnlitMaterial) -> Void
    ) {
        guard let placement = resolver.terrainPlacement(
            graphicIndex: graphicIndex, tileset: tileset) else { return }
        material(for: placement, completion: completion)
    }

    /// Requests the real unit sprite material for a snapshot unit's current
    /// engine-resolved frame (mirror baked into the texture).
    ///
    /// `frameOverride`/`mirrorOverride` let the caller request a camera-relative
    /// directional frame (see `TabletopSpriteDirection`) rather than the unit's
    /// own map-relative one; when `nil` the unit's engine frame/mirror are used.
    public func unitMaterial(
        unit: TabletopGameplayUnit,
        sprite: TabletopUnitSpriteInfo?,
        frameOverride: Int? = nil,
        mirrorOverride: Bool? = nil,
        completion: @escaping (UnlitMaterial) -> Void
    ) {
        guard let placement = resolver.unitPlacement(
            unit: unit, sprite: sprite,
            frameOverride: frameOverride, mirrorOverride: mirrorOverride) else { return }
        material(for: placement, completion: completion)
    }

    /// Evicts every cached material (call when tearing down a scenario).
    public func clear() {
        cache.removeAll()
    }

    // MARK: - Atlas material

    /// Asynchronously builds a bounded multi-row atlas material that packs
    /// all terrain graphicIndices defined in `slotMap` into one texture.
    ///
    /// Each slot uses the padded content bounds supplied by `atlasLayout`, the
    /// same UV layout used by `TabletopTerrainChunkMeshBuilder`.
    ///
    /// Fires `completion` on the main actor with a non-nil material when at least
    /// one slot decoded successfully; `nil` otherwise (caller keeps procedural).
    ///
    /// Both atlas dimensions are bounded by Metal's maximum 2D texture size.
    public static nonisolated let maxAtlasPixelDimension =
        TabletopTerrainAtlasLayout.maximumTextureDimension

    /// Backward-compatible entry point for callers that do not need to share an
    /// explicit padded layout with prebuilt geometry.
    public func buildTerrainAtlas(
        slotMap: TabletopAtlasSlotMap,
        tileset: TabletopTilesetInfo?,
        completion: @escaping (PhysicallyBasedMaterial?) -> Void
    ) {
        let layout = TabletopTerrainAtlasLayout(
            slotCount: slotMap.slotCount,
            cellWidth: max(1, tileset?.pixelTileWidth ?? 1),
            cellHeight: max(1, tileset?.pixelTileHeight ?? 1),
            gutterPixels: 0)
        buildTerrainAtlas(
            slotMap: slotMap, atlasLayout: layout,
            tileset: tileset, completion: completion)
    }

    public func buildTerrainAtlas(
        slotMap:  TabletopAtlasSlotMap,
        atlasLayout: TabletopTerrainAtlasLayout,
        tileset:  TabletopTilesetInfo?,
        completion: @escaping (PhysicallyBasedMaterial?) -> Void
    ) {
        // All slots share the same tileset, so its generated-cache-ness (and
        // therefore which root applies) is determined once up front rather
        // than per placement — from the explicit ABI v5 `pathRoot`
        // discriminator, never inferred from the filename.
        let isGeneratedCache = tileset?.pathRoot == .cacheRoot
        let root     = isGeneratedCache ? (cacheRoot ?? dataRoot) : dataRoot
        let resolver = self.resolver

        decodeQueue.async { [weak self] in
            // Decode each slot's tile image off the main actor.
            var slotImages: [Int: CGImage] = [:]
            for entry in slotMap.slotEntries {
                guard let placement = resolver.terrainPlacement(
                    graphicIndex: entry.graphicIndex, tileset: tileset) else { continue }
                guard let img = WargusTabletopMaterialProvider.decode(
                    root: root, placement: placement) else { continue }
                slotImages[entry.slotIndex] = img
            }

            guard !slotImages.isEmpty else {
                Task { @MainActor in completion(nil) }
                return
            }

            // Determine atlas cell dimensions from the first decoded image.
            guard let firstImg = slotImages.values.first else {
                Task { @MainActor in completion(nil) }
                return
            }
            let cellW   = firstImg.width
            let cellH   = firstImg.height
            let N       = slotMap.slotCount
            guard atlasLayout.isValid,
                  atlasLayout.slotCount == N,
                  atlasLayout.cellWidth == cellW,
                  atlasLayout.cellHeight == cellH else {
                Task { @MainActor in completion(nil) }
                return
            }
            let atlasW  = atlasLayout.atlasWidth
            let atlasH  = atlasLayout.atlasHeight
            guard atlasW > 0, atlasH > 0,
                  atlasW <= WargusTabletopMaterialProvider.maxAtlasPixelDimension,
                  atlasH <= WargusTabletopMaterialProvider.maxAtlasPixelDimension else {
                tabletopEngineLog(
                    "[Tabletop] atlas skipped: \(N) padded slots = "
                    + "\(atlasW)x\(atlasH)px (limit "
                    + "\(WargusTabletopMaterialProvider.maxAtlasPixelDimension)px)")
                Task { @MainActor in completion(nil) }
                return
            }

            guard let atlasImage = TabletopTerrainAtlasImageBuilder.build(
                slotImages: slotImages, layout: atlasLayout) else {
                Task { @MainActor in completion(nil) }
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { completion(nil); return }
                completion(self.makeLitTerrainMaterial(cgImage: atlasImage))
            }
        }
    }

    // MARK: - Core resolve

    private func material(
        for placement: TabletopAssetPlacement,
        completion: @escaping (UnlitMaterial) -> Void
    ) {
        let key = placement.cacheKey
        if let cached = cache.value(forKey: key) {
            completion(cached)
            return
        }
        // Coalesce: if a decode for this key is already running, just queue this
        // caller's completion — it will be invoked when the shared decode lands.
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]

        let root = self.root(for: placement)
        decodeQueue.async { [weak self] in
            let cgImage = WargusTabletopMaterialProvider.decode(root: root, placement: placement)
            Task { @MainActor in
                guard let self else { return }
                let waiters = self.pending.removeValue(forKey: key) ?? []
                // Per-asset fallback: on any decode failure every waiter keeps
                // its procedural content (no completion is invoked).
                guard let cgImage,
                      let material = self.makeMaterial(cgImage: cgImage) else { return }
                self.cache.setValue(material, forKey: key)
                for waiter in waiters { waiter(material) }
            }
        }
    }

    /// Main-actor RealityKit material creation from a fully-processed CGImage.
    private func makeMaterial(cgImage: CGImage) -> UnlitMaterial? {
        guard let texture = try? TextureResource(
            image: cgImage,
            options: TextureResource.CreateOptions(semantic: .color)
        ) else { return nil }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        // Sprites and cut-out tiles carry alpha; blend so transparency shows.
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        material.opacityThreshold = 0.5
        return material
    }

    /// Main-actor lit terrain-atlas material. Terrain is opaque (gray-filled
    /// atlas slots), so a `PhysicallyBasedMaterial` lets the relief cliffs and
    /// slopes shade under the scene light — the depth cue that an unlit terrain
    /// surface cannot provide.
    private func makeLitTerrainMaterial(cgImage: CGImage) -> PhysicallyBasedMaterial? {
        guard let texture = try? TextureResource(
            image: cgImage,
            options: TextureResource.CreateOptions(semantic: .color)
        ) else { return nil }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: .init(texture))
        material.roughness = 1.0
        material.metallic  = 0.0
        return material
    }

    // MARK: - Off-actor decode / crop / mirror / tint

    /// Loads, crops, mirrors, and tints a placement into a CGImage entirely off
    /// the main actor. Returns `nil` on any failure (missing/corrupt file,
    /// out-of-bounds frame) so the caller keeps procedural content.
    nonisolated static func decode(
        root: URL, placement: TabletopAssetPlacement
    ) -> CGImage? {
        guard let url = TabletopAssetPath.resolvedURL(
            root: root, relative: placement.relativePath) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let uiImage = UIImage(data: data),
              let full = uiImage.cgImage else { return nil }

        let imageWidth = full.width
        let imageHeight = full.height

        // Crop the atlas frame (or use the whole image for un-gridded assets).
        let cropped: CGImage
        if let rect = placement.sourceRect(imageWidth: imageWidth, imageHeight: imageHeight) {
            guard let sub = full.cropping(to: CGRect(
                x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else { return nil }
            cropped = sub
        } else if placement.cellWidth > 0 {
            // A grid was requested but the frame fell out of bounds: fail so the
            // caller keeps procedural content rather than showing a wrong tile.
            return nil
        } else {
            cropped = full
        }

        return render(cropped, mirror: placement.mirror, tint: placement.teamTint)
    }

    /// Draws `image` into a fresh ARGB context, applying a horizontal mirror
    /// and/or a team tint. Returns the composited CGImage.
    nonisolated private static func render(
        _ image: CGImage, mirror: Bool, tint: TabletopTeamTint?
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }

        ctx.interpolationQuality = .none
        if mirror {
            // Flip horizontally: translate then negate the x scale.
            ctx.translateBy(x: CGFloat(width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        // CGBitmapContext uses a y-up coordinate system; CGImage rows are y-down.
        // Without a vertical flip, ctx.draw() places the image's first row at
        // the canvas bottom, producing an upside-down texture in RealityKit
        // (which uses Metal's y-down UV convention). Flip here so visual row 0
        // lands at the canvas top, regardless of whether mirror is also set.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(image, in: rect)

        // Team tint: a gentle multiply biased toward white so the sprite stays
        // legible while conveying ownership. (Exact palette-index remap of only
        // the team-colored pixels is a follow-up requiring indexed decode.)
        if let tint {
            ctx.setBlendMode(.multiply)
            let r = CGFloat(0.55 + 0.45 * tint.red)
            let g = CGFloat(0.55 + 0.45 * tint.green)
            let b = CGFloat(0.55 + 0.45 * tint.blue)
            ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
            // Only tint where the sprite is opaque, preserving cut-out edges.
            ctx.setBlendMode(.multiply)
            ctx.clip(to: rect, mask: image)
            ctx.fill(rect)
        }

        return ctx.makeImage()
    }
}
