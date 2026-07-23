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

    public init(dataRoot: URL, cacheCapacity: Int = 512) {
        self.dataRoot = dataRoot
        self.cache = TabletopLRUCache(capacity: cacheCapacity)
    }

    /// Builds a provider rooted at the staged data directory, or `nil` when it
    /// does not exist (the board then renders fully procedurally — an explicit,
    /// per-app absence, not a silent fallback masking a broken pipeline).
    public static func make(
        dataPath: String,
        fileManager: FileManager = .default
    ) -> WargusTabletopMaterialProvider? {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dataPath, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        return WargusTabletopMaterialProvider(
            dataRoot: URL(fileURLWithPath: dataPath, isDirectory: true))
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
    public func unitMaterial(
        unit: TabletopGameplayUnit,
        sprite: TabletopUnitSpriteInfo?,
        completion: @escaping (UnlitMaterial) -> Void
    ) {
        guard let placement = resolver.unitPlacement(unit: unit, sprite: sprite) else { return }
        material(for: placement, completion: completion)
    }

    /// Evicts every cached material (call when tearing down a scenario).
    public func clear() {
        cache.removeAll()
    }

    // MARK: - Atlas material

    /// Asynchronously builds a horizontal-strip atlas `UnlitMaterial` that packs
    /// all terrain graphicIndices defined in `slotMap` into one texture.
    ///
    /// Each slot s (0-based) occupies u ∈ [s/N, (s+1)/N] so the same UV layout
    /// used by `TabletopTerrainChunkMeshBuilder` applies to both the tiny
    /// procedural-colour placeholder and this real-art atlas.
    ///
    /// Fires `completion` on the main actor with a non-nil material when at least
    /// one slot decoded successfully; `nil` otherwise (caller keeps procedural).
    ///
    /// Atlas width is bounded by `maxAtlasPixelWidth` to stay within Metal's
    /// maximum 2D texture limit (typically 16 384 px). When the computed width
    /// would exceed this limit the atlas is not created and `nil` is returned.
    public static nonisolated let maxAtlasPixelWidth = 8_192   // conservative; Metal allows 16384

    public func buildTerrainAtlas(
        slotMap:  TabletopAtlasSlotMap,
        tileset:  TabletopTilesetInfo?,
        completion: @escaping (UnlitMaterial?) -> Void
    ) {
        let root     = dataRoot
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
            let atlasW  = N * cellW
            let atlasH  = cellH
            // Guard against exceeding Metal's maximum texture dimension.
            guard atlasW > 0, atlasH > 0,
                  atlasW <= WargusTabletopMaterialProvider.maxAtlasPixelWidth else {
                tabletopEngineLog(
                    "[Tabletop] atlas skipped: \(N) slots × \(cellW)px = \(atlasW)px "
                    + "(limit \(WargusTabletopMaterialProvider.maxAtlasPixelWidth)px)")
                Task { @MainActor in completion(nil) }
                return
            }

            // Pack all slot images into a single horizontal-strip atlas.
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            guard let ctx = CGContext(
                data: nil, width: atlasW, height: atlasH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: bitmapInfo) else {
                Task { @MainActor in completion(nil) }
                return
            }
            ctx.interpolationQuality = .none
            // Flood the entire atlas with a neutral fallback before drawing
            // decoded tiles.  This prevents transparent holes for any slot
            // whose graphicIndex is nil or whose image failed to decode —
            // those slots show a neutral grey rather than a transparent cutout
            // that would expose the RealityKit background.
            ctx.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(atlasW), height: CGFloat(atlasH)))
            // Match the y-flip applied by decode() so atlas tiles are not
            // inverted relative to tiles decoded by the single-material path.
            ctx.translateBy(x: 0, y: CGFloat(atlasH))
            ctx.scaleBy(x: 1, y: -1)
            for (slot, img) in slotImages {
                let x = CGFloat(slot * cellW)
                ctx.draw(img, in: CGRect(x: x, y: 0,
                                        width: CGFloat(cellW), height: CGFloat(cellH)))
            }
            guard let atlasImage = ctx.makeImage() else {
                Task { @MainActor in completion(nil) }
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { completion(nil); return }
                completion(self.makeMaterial(cgImage: atlasImage))
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

        let root = dataRoot
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
