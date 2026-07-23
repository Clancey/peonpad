// TabletopSceneBuilder.swift
//
// Builds the procedural, non-proprietary tabletop content: the board
// surface, a fog-of-war overlay that stays glued to the board plane, and a
// handful of upright transparent "cylindrical billboard" test units. None of
// this depends on real Warcraft II art or data -- it is only a stand-in to
// prove the spatial board/billboard/gesture mechanics.
import RealityKit
import SwiftUI
import UIKit

/// `UnlitMaterial(color:)` does not automatically read the alpha component of
/// the given `UIColor` into the material's blending mode -- passing a
/// translucent color renders fully opaque unless blending is set explicitly.
/// Every "transparent" surface in this file (cylindrical unit bodies, the
/// fog-of-war plane, dimmed/deselected billboards) goes through this helper
/// so alpha actually takes visual effect.
func translucentUnlitMaterial(_ color: UIColor) -> UnlitMaterial {
    var material = UnlitMaterial(color: color)
    let alpha = Float(color.cgColor.alpha)
    if alpha < 1 {
        material.blending = .transparent(opacity: .init(floatLiteral: alpha))
    }
    return material
}

/// One procedural test unit's static board-relative placement, independent
/// of RealityKit. `facingRadians` follows the `WarcraftFacing` convention:
/// 0 = board north (+Z), increasing clockwise.
struct TabletopUnitSpec {
    var id: String
    var tileX: Int
    var tileZ: Int
    var facingRadians: Double
    var tint: UIColor
    /// Engine unit-type ident (e.g. "unit-footman") for asset resolution.
    var unitKind: String = ""
}

enum TabletopBoardMetrics {
    /// Fixed physical footprint of the board (meters). An arbitrary engine map
    /// is scaled to fit this square via `TabletopMapFit`, so the user always
    /// manipulates the same-size board regardless of scenario dimensions.
    static let physicalExtent: Float = 0.84
    static var halfExtent: Float { physicalExtent / 2 }

    /// Reference tile size (the original 7×7 demo board's tile). Unit body
    /// dimensions scale relative to this so units stay proportional as the map
    /// grows and tiles shrink.
    static let referenceTileSize: Float = 0.12

    static let unitHeight: Float = 0.16
    static let unitRadius: Float = 0.03

    /// The fit that scales the given snapshot's map onto the physical board.
    static func fit(for snapshot: TabletopGameplaySnapshot) -> TabletopMapFit {
        TabletopMapFit(
            width: snapshot.mapSize.width,
            height: snapshot.mapSize.height,
            boardExtent: physicalExtent)
    }

    /// Board-local position (relative to the board root) of the center of tile
    /// (tileX, tileZ) under the given fit, with (0,0) at the board center.
    static func tileCenter(_ fit: TabletopMapFit, tileX: Int, tileZ: Int) -> SIMD3<Float> {
        let c = fit.tileCenter(tileX: tileX, tileZ: tileZ)
        return SIMD3<Float>(c.x, 0, c.z)
    }
}

enum TabletopTestRoster {
    /// A small, deliberately varied set of procedural test units: one for
    /// every canonical Warcraft II sprite direction, plus a couple of
    /// mirrored-direction cases, so the directional-frame behavior is
    /// visually obvious from any viewing angle around the board.
    static let units: [TabletopUnitSpec] = [
        TabletopUnitSpec(id: "sentry.north", tileX: 0, tileZ: -2, facingRadians: WarcraftFacing.north.radians, tint: .systemRed),
        TabletopUnitSpec(id: "sentry.northeast", tileX: 2, tileZ: -1, facingRadians: WarcraftFacing.northEast.radians, tint: .systemOrange),
        TabletopUnitSpec(id: "sentry.east", tileX: 2, tileZ: 1, facingRadians: WarcraftFacing.east.radians, tint: .systemYellow),
        TabletopUnitSpec(id: "sentry.southeast", tileX: 1, tileZ: 2, facingRadians: WarcraftFacing.southEast.radians, tint: .systemGreen),
        TabletopUnitSpec(id: "sentry.south", tileX: -1, tileZ: 2, facingRadians: WarcraftFacing.south.radians, tint: .systemTeal),
        TabletopUnitSpec(id: "sentry.southwest", tileX: -2, tileZ: 1, facingRadians: WarcraftFacing.southWest.radians, tint: .systemBlue),
        TabletopUnitSpec(id: "sentry.west", tileX: -2, tileZ: -1, facingRadians: WarcraftFacing.west.radians, tint: .systemPurple),
        TabletopUnitSpec(id: "sentry.northwest", tileX: -1, tileZ: -2, facingRadians: WarcraftFacing.northWest.radians, tint: .systemPink),
    ]
}

/// A live RealityKit unit built from a `TabletopUnitSpec`: the invisible hit
/// box (also the unit root, positioned at the tile's feet), the transparent
/// cylindrical body, and the inner quad that is re-oriented and re-tinted
/// every frame to face the viewer while preserving the unit's world-fixed
/// logical facing.
final class TabletopLiveUnit {
    let spec: TabletopUnitSpec
    let root: Entity
    let quad: ModelEntity
    let body: ModelEntity
    /// Bright disc shown on the terrain under a selected unit.
    let selectionRing: ModelEntity
    let baseMaterial: UnlitMaterial
    let mirroredMaterial: UnlitMaterial

    /// Selection state and the currently-resolved directional hue are both
    /// stored here so `setSelected` and `applyDirectionalFrame` -- one
    /// driven by right-hand command intents, the other re-run every frame
    /// by `refreshBillboards()` -- always compose into a single material
    /// update instead of independently overwriting each other's alpha.
    private(set) var isSelected = false
    private var currentHue: UIColor
    /// When a real Wargus sprite material has been resolved for this unit, it
    /// is stored here and drawn on the quad instead of the procedural canonical
    /// hue. The engine already baked facing + animation + mirror into the
    /// texture, so the per-frame directional re-tint/mirror is skipped; only the
    /// viewer-facing yaw and selection alpha are still applied.
    private var spriteMaterial: UnlitMaterial?

    /// Descriptor + latest engine state for a *directional* real sprite,
    /// retained so the per-frame billboard pass can recompute the
    /// camera-relative directional frame (and request the matching texture) as
    /// the board is orbited, without rescanning the snapshot every frame. `nil`
    /// for procedural units, non-directional sprites (buildings/resources), or
    /// before a sprite descriptor has been resolved.
    struct DirectionalSprite {
        var sprite: TabletopUnitSpriteInfo
        var unit: TabletopGameplayUnit
    }
    private var directionalSprite: DirectionalSprite?
    /// The camera-relative frame most recently requested, so an unchanged
    /// viewer azimuth / animation step does not re-request the same texture.
    private var lastResolvedDirection: TabletopSpriteDirection.Frame?

    /// The unit's current board-space facing (radians, 0 = board north,
    /// increasing clockwise). Starts from `spec.facingRadians` and may be
    /// updated incrementally from engine snapshots without recreating the
    /// entity. Read by `applyDirectionalFrame` every SceneEvents.Update tick.
    var currentFacingRadians: Double

    /// The unit's current owner/team tint. Updated when an engine snapshot
    /// reports an ownership change; drives both body and quad materials.
    private var currentOwnerTint: UIColor

    init(spec: TabletopUnitSpec, fit: TabletopMapFit) {
        self.spec = spec
        self.currentHue = spec.tint
        self.currentFacingRadians = spec.facingRadians
        self.currentOwnerTint = spec.tint

        // Scale unit body/quad with the fitted tile size so units stay
        // proportional as the map grows and tiles shrink, with a floor so units
        // stay readable (not tiny) even on large maps.
        let scale = max(fit.tileSize / TabletopBoardMetrics.referenceTileSize, 0.34)
        let unitHeight = TabletopBoardMetrics.unitHeight * scale
        let unitRadius = TabletopBoardMetrics.unitRadius * scale

        let root = Entity()
        root.name = "unit.\(spec.id)"
        root.position = TabletopBoardMetrics.tileCenter(fit, tileX: spec.tileX, tileZ: spec.tileZ)
        root.components.set(InputTargetComponent())
        root.components.set(
            CollisionComponent(shapes: [
                .generateBox(size: SIMD3<Float>(
                    unitRadius * 2.2,
                    unitHeight,
                    unitRadius * 2.2
                ))
                .offsetBy(translation: [0, unitHeight / 2, 0])
            ])
        )
        root.components.set(HoverEffectComponent())

        let body = ModelEntity(
            mesh: .generateCylinder(height: unitHeight, radius: unitRadius),
            materials: [translucentUnlitMaterial(spec.tint.withAlphaComponent(0.22))]
        )
        body.name = root.name + ".body"
        body.position = [0, unitHeight / 2, 0]
        root.addChild(body)

        let quad = ModelEntity(
            mesh: .generatePlane(width: unitRadius * 1.7, height: unitHeight * 0.85),
            materials: [translucentUnlitMaterial(spec.tint)]
        )
        quad.name = root.name + ".quad"
        quad.position = [0, unitHeight / 2, 0]
        root.addChild(quad)

        // Contact shadow: a soft dark disc on the terrain directly under the
        // unit, so the upright billboard reads as standing *on* the board
        // rather than floating.
        let shadow = ModelEntity(
            mesh: .generateCylinder(height: 0.0004, radius: unitRadius * 1.7),
            materials: [translucentUnlitMaterial(UIColor(white: 0, alpha: 0.33))]
        )
        shadow.name = root.name + ".shadow"
        shadow.position = [0, 0.0007, 0]
        root.addChild(shadow)

        // Selection ring: a bright disc just under the shadow, enabled only when
        // the unit is selected, anchored at the unit's feet (terrain height).
        let ring = ModelEntity(
            mesh: .generateCylinder(height: 0.0003, radius: unitRadius * 2.4),
            materials: [translucentUnlitMaterial(UIColor.systemYellow.withAlphaComponent(0.9))]
        )
        ring.name = root.name + ".selectionRing"
        ring.position = [0, 0.0003, 0]
        ring.isEnabled = false
        root.addChild(ring)

        self.root = root
        self.quad = quad
        self.body = body
        self.selectionRing = ring
        self.baseMaterial = translucentUnlitMaterial(spec.tint)
        self.mirroredMaterial = translucentUnlitMaterial(spec.tint.withAlphaComponent(0.85))
    }

    /// Highlights or un-highlights this unit to give visible feedback for
    /// the right-hand selection command intent. Composes with whatever
    /// directional hue is currently resolved rather than overwriting it, so
    /// the next per-frame `applyDirectionalFrame` call doesn't need to
    /// (re)decide the selection alpha itself.
    func setSelected(_ selected: Bool) {
        isSelected = selected
        selectionRing.isEnabled = selected
        applyQuadMaterial()
        applyBodyMaterial()
    }

    /// Shows or hides this unit to reflect its alive/dead state. A dead unit
    /// (hp == 0) is disabled so it neither renders nor receives input.
    func setAlive(_ alive: Bool) {
        root.isEnabled = alive
    }

    /// Updates the owner/team tint (e.g. after a capture or engine-driven
    /// ownership change) and refreshes all materials immediately.
    func updateOwnerTint(_ tint: UIColor) {
        currentOwnerTint = tint
        // Reset the directional hue to the new base tint so the next
        // applyDirectionalFrame uses the correct colour for canonical-
        // direction shading.
        currentHue = tint
        applyQuadMaterial()
        applyBodyMaterial()
    }

    /// Applies a real Wargus sprite material to the quad (from the material
    /// provider). Composes with the current selection alpha. Passing a new
    /// material for a changed engine frame swaps the texture without recreating
    /// the entity; passing repeatedly with the same frame is cheap (the
    /// provider caches the decoded texture).
    func setSpriteMaterial(_ material: UnlitMaterial) {
        spriteMaterial = material
        // A real sprite bakes its own mirror into the texture, so clear any
        // procedural horizontal flip left on the quad.
        quad.scale.x = abs(quad.scale.x)
        applyQuadMaterial()
    }

    /// Records the descriptor + latest engine state for a directional real
    /// sprite so the per-frame billboard pass can pick the camera-relative
    /// column. Passing `nil` (procedural or non-directional sprite) disables
    /// camera-relative reselection. Resets the last-resolved cache so the next
    /// per-frame pass always re-requests the correct frame.
    func setDirectionalSprite(_ state: DirectionalSprite?) {
        directionalSprite = state
        lastResolvedDirection = nil
    }

    /// Whether this unit has a directional real sprite that should be
    /// reselected per-frame from the viewer's azimuth.
    var hasDirectionalSprite: Bool {
        guard let d = directionalSprite else { return false }
        return d.sprite.numDirections > 1
    }

    /// Resolves the camera-relative directional frame for the current viewer
    /// azimuth, or `nil` when this unit has no directional sprite or the frame
    /// is unchanged since it was last returned (so the caller skips a redundant
    /// texture request). Uses `currentFacingRadians` so engine facing updates
    /// compose with the live camera azimuth.
    func cameraRelativeSpriteFrame(
        viewerAzimuthRadians: Double
    ) -> (unit: TabletopGameplayUnit, sprite: TabletopUnitSpriteInfo, frame: Int, mirror: Bool)? {
        guard let d = directionalSprite, d.sprite.numDirections > 1 else { return nil }
        let resolved = TabletopSpriteDirection.resolve(
            engineFrame: d.unit.spriteFrame ?? 0,
            engineMirror: d.unit.spriteMirror ?? false,
            numDirections: d.sprite.numDirections,
            flip: d.sprite.flip,
            unitFacingRadians: currentFacingRadians,
            viewerAzimuthRadians: viewerAzimuthRadians)
        if resolved == lastResolvedDirection { return nil }
        lastResolvedDirection = resolved
        return (d.unit, d.sprite, resolved.frame, resolved.mirror)
    }

    /// Applies the current directional hue and the current selection alpha
    /// to the quad in one material assignment, so neither `setSelected` nor
    /// `applyDirectionalFrame` ever clobbers the other's contribution.
    private func applyQuadMaterial() {
        let alpha = TabletopUnitAppearance.quadAlpha(selected: isSelected)
        if let spriteMaterial {
            var material = spriteMaterial
            material.blending = .transparent(opacity: .init(floatLiteral: Float(alpha)))
            quad.model?.materials = [material]
            return
        }
        quad.model?.materials = [translucentUnlitMaterial(currentHue.withAlphaComponent(CGFloat(alpha)))]
    }

    /// Applies the current selection alpha to the cylindrical body using the
    /// current owner tint. The body has no directional hue of its own, so
    /// this only needs selection state and the current owner colour.
    private func applyBodyMaterial() {
        let alpha = TabletopUnitAppearance.bodyAlpha(selected: isSelected)
        body.model?.materials = [translucentUnlitMaterial(currentOwnerTint.withAlphaComponent(CGFloat(alpha)))]
    }

    /// Applies this frame's directional-frame resolution: rotates the quad
    /// to face the viewer around the board's vertical normal, mirrors it
    /// horizontally when the resolved canonical facing requires it, and
    /// tints it to make the selected canonical direction legible even
    /// without real sprite art. Uses `currentFacingRadians` rather than
    /// the immutable `spec.facingRadians` so engine-driven facing updates
    /// take effect on the next frame without recreating the entity.
    func applyDirectionalFrame(viewerBoardPosition: TabletopPoint3D, boardRoot: Entity) {
        let unitBoardPosition = TabletopPoint3D(
            x: Double(root.position(relativeTo: boardRoot).x),
            y: 0,
            z: Double(root.position(relativeTo: boardRoot).z)
        )
        let viewerAzimuth = TabletopViewerAzimuth.aroundBoardCenter(viewerBoardPosition: viewerBoardPosition)
        let resolution = TabletopDirectionalFrame.resolve(
            unitFacingRadians: currentFacingRadians,
            viewerAzimuthRadians: viewerAzimuth
        )

        // Rotate the quad's neutral +Z-facing normal to point toward the
        // viewer, purely around the board's vertical (Y) normal -- the same
        // deterministic (atan2(dx, dz), 0 = north, clockwise) convention
        // that TabletopBillboardOrientation's unit tests exercise, so the
        // rendered billboard can never tilt/pitch/roll away from upright.
        let yaw = TabletopBillboardOrientation.yawFacingViewer(
            unitBoardPosition: unitBoardPosition,
            viewerBoardPosition: viewerBoardPosition
        )
        quad.orientation = simd_quatf(angle: Float(yaw), axis: [0, 1, 0])

        // With a real Wargus sprite, the engine already resolved the facing +
        // animation frame and mirror into the texture, so the quad only needs
        // to yaw toward the viewer — skip the procedural canonical re-tint and
        // horizontal flip (and don't reassign the material every frame, which
        // would churn the texture).
        if spriteMaterial != nil { return }

        // Mirroring is represented procedurally (no sprite art is embedded):
        // a horizontally-flipped scale plus a dimmer tint stands in for
        // "this canonical frame is being mirrored", while the hue always
        // reflects the resolved canonical direction. The hue is stored and
        // composed with the current selection alpha via applyQuadMaterial()
        // rather than assigned directly, so this per-frame call can never
        // erase whatever setSelected last decided.
        currentHue = TabletopTestRoster.canonicalTint(resolution.canonical, base: spec.tint)
        quad.scale.x = resolution.mirrored ? -abs(quad.scale.x) : abs(quad.scale.x)
        applyQuadMaterial()
    }
}

extension TabletopTestRoster {
    /// A small, deterministic tint per canonical stored direction so the
    /// resolved (unitFacing - viewerAzimuth) frame is visually legible
    /// without any real sprite art.
    static func canonicalTint(_ canonical: WarcraftCanonicalFacing, base: UIColor) -> UIColor {
        let brightness: CGFloat
        switch canonical {
        case .north: brightness = 1.0
        case .northEast: brightness = 0.88
        case .east: brightness = 0.76
        case .southEast: brightness = 0.64
        case .south: brightness = 0.52
        }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var value: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        return UIColor(hue: hue, saturation: saturation, brightness: max(0.35, brightness), alpha: 1.0)
    }
}

// MARK: - Gameplay unit → spec mapping

extension TabletopUnitSpec {
    /// Converts a pure-state `TabletopGameplayUnit` to the RealityKit-facing
    /// `TabletopUnitSpec`. The owner index is mapped to a representative tint
    /// so each player's units are visually distinguishable without real art.
    init(gameplayUnit: TabletopGameplayUnit) {
        self.id = gameplayUnit.id
        self.tileX = gameplayUnit.tileX
        self.tileZ = gameplayUnit.tileZ
        self.facingRadians = gameplayUnit.facingRadians
        self.tint = TabletopBoardBuilder.ownerTint(owner: gameplayUnit.owner)
        self.unitKind = gameplayUnit.kind
    }
}

// MARK: - Terrain color mapping

extension TabletopTerrainKind {
    /// A representative `UIColor` for each terrain kind, used to tint board
    /// tiles when the board is built from a `TabletopGameplaySnapshot`.
    var tileColor: UIColor {
        switch self {
        case .grass:  return UIColor(white: 0.70, alpha: 1)
        case .dirt:   return UIColor(white: 0.45, alpha: 1)
        case .water:  return UIColor(hue: 0.57, saturation: 0.65, brightness: 0.45, alpha: 1)
        case .rock:   return UIColor(white: 0.22, alpha: 1)
        case .forest: return UIColor(hue: 0.34, saturation: 0.55, brightness: 0.30, alpha: 1)
        }
    }
}

enum TabletopBoardBuilder {
    /// Maps a player/team index to a representative unit tint so that units
    /// belonging to different players are visually distinguishable.
    static func ownerTint(owner: Int) -> UIColor {
        switch owner {
        case 0:  return .systemBlue
        case 1:  return .systemRed
        default: return .systemGray
        }
    }

    /// Builds the board surface from a gameplay snapshot: one terrain quad per
    /// map cell plus a per-tile fog-of-war quad above it (hidden when the tile
    /// is revealed, shown as a dark overlay when not). A very faint global
    /// haze plane sits above everything for aesthetic continuity.
    ///
    /// Returns a dictionary from tile key to `ModelEntity`. Keys use two
    /// namespaces so both categories can live in one dictionary:
    ///   `tileEntityKey(tileX:tileZ:)`  — terrain quads ("tileX.tileZ")
    ///   `fogEntityKey(tileX:tileZ:)`   — per-tile fog quads ("fog.tileX.tileZ")
    @discardableResult
    @MainActor
    static func addSurface(
        to boardRoot: Entity,
        snapshot: TabletopGameplaySnapshot,
        fit: TabletopMapFit,
        resolver: TabletopAssetResolver = NullTabletopAssetResolver(),
        materialProvider: WargusTabletopMaterialProvider? = nil
    ) -> [String: ModelEntity] {
        var tileEntities: [String: ModelEntity] = [:]
        let quadSize = fit.tileQuadSize
        let tileset = snapshot.assets?.tileset
        // Iterate the snapshot's actual terrain so any map size (32×32, 64×64,
        // 96×96, …) is laid out; the fit scales each tile onto the fixed board.
        for terrainTile in snapshot.terrain {
            let tileX = terrainTile.tileX
            let tileZ = terrainTile.tileZ

            // Terrain quad: real texture via the resolver when available,
            // otherwise a color derived from the engine's terrain class.
            let tile = ModelEntity(
                mesh: .generatePlane(width: quadSize, depth: quadSize),
                materials: [terrainMaterial(kind: terrainTile.kind, resolver: resolver)]
            )
            tile.name = "board.tile.\(tileX).\(tileZ)"
            tile.position = TabletopBoardMetrics.tileCenter(fit, tileX: tileX, tileZ: tileZ)
            boardRoot.addChild(tile)
            tileEntities[tileEntityKey(tileX: tileX, tileZ: tileZ)] = tile

            // Real Wargus tile art from the staged data dir, when available.
            // The procedural color shows until (and only if) the decode
            // succeeds — a per-tile progressive enhancement, not a silent
            // whole-app fallback.
            if let materialProvider {
                materialProvider.terrainMaterial(
                    graphicIndex: terrainTile.graphicIndex, tileset: tileset
                ) { [weak tile] material in
                    tile?.model?.materials = [material]
                }
            }

            // Per-tile fog overlay quad, slightly above the terrain. Enabled
            // (dark) when unrevealed; disabled (invisible) when revealed.
            let fogQuad = ModelEntity(
                mesh: .generatePlane(width: quadSize, depth: quadSize),
                materials: [translucentUnlitMaterial(UIColor(white: 0.06, alpha: 0.88))]
            )
            fogQuad.name = "board.fog.\(tileX).\(tileZ)"
            var fogPos = TabletopBoardMetrics.tileCenter(fit, tileX: tileX, tileZ: tileZ)
            fogPos.y = 0.005  // just above the terrain quad
            fogQuad.position = fogPos
            fogQuad.isEnabled = !snapshot.fog(atTileX: tileX, tileZ: tileZ)
            boardRoot.addChild(fogQuad)
            tileEntities[fogEntityKey(tileX: tileX, tileZ: tileZ)] = fogQuad
        }

        // Subtle global haze plane for aesthetic continuity (very low alpha).
        let haze = ModelEntity(
            mesh: .generatePlane(
                width: TabletopBoardMetrics.physicalExtent * 1.02,
                depth: TabletopBoardMetrics.physicalExtent * 1.02
            ),
            materials: [translucentUnlitMaterial(UIColor(white: 0.85, alpha: 0.06))]
        )
        haze.name = "board.haze"
        haze.position = [0, 0.01, 0]
        boardRoot.addChild(haze)
        return tileEntities
    }

    /// Resolves a terrain tile's material: a real texture from the asset
    /// resolver when the running app actually has it, otherwise the procedural
    /// color derived from the engine terrain class. No proprietary art is
    /// bundled, so this is the procedural fallback until a catalog is injected.
    static func terrainMaterial(
        kind: TabletopTerrainKind,
        resolver: TabletopAssetResolver
    ) -> UnlitMaterial {
        if let name = resolver.terrainTexture(for: kind),
           let texture = try? TextureResource.load(named: name) {
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            return material
        }
        return translucentUnlitMaterial(kind.tileColor)
    }

    /// Builds a single live RealityKit unit from a gameplay snapshot unit and
    /// parents it to `boardRoot`. Returns the live unit for tracking. When a
    /// material provider and sprite descriptor are available, the unit's real
    /// Wargus sprite is requested and applied progressively.
    @MainActor
    static func addUnit(
        _ gameplayUnit: TabletopGameplayUnit,
        to boardRoot: Entity,
        snapshot: TabletopGameplaySnapshot,
        fit: TabletopMapFit,
        materialProvider: WargusTabletopMaterialProvider? = nil
    ) -> TabletopLiveUnit {
        let spec = TabletopUnitSpec(gameplayUnit: gameplayUnit)
        let liveUnit = TabletopLiveUnit(spec: spec, fit: fit)
        liveUnit.setAlive(gameplayUnit.isAlive)
        liveUnit.setSelected(snapshot.selection.selectedUnitID == gameplayUnit.id)
        boardRoot.addChild(liveUnit.root)
        refreshUnitSprite(liveUnit, unit: gameplayUnit, snapshot: snapshot,
                          materialProvider: materialProvider)
        return liveUnit
    }

    /// Requests the real Wargus sprite material for a unit's current engine
    /// frame and applies it when it decodes. Safe to call repeatedly (e.g. on
    /// each animation-frame change); the provider caches decoded textures so an
    /// unchanged frame does not re-read the disk.
    ///
    /// For a *directional* sprite the map-relative engine frame is not requested
    /// here; instead the unit's directional descriptor is recorded so the
    /// per-frame billboard pass (`refreshDirectionalSprites`) can request the
    /// camera-relative column as the board is orbited. Non-directional sprites
    /// (buildings, resources, single-frame units) request the engine frame
    /// directly since they never re-orient with the camera.
    @MainActor
    static func refreshUnitSprite(
        _ liveUnit: TabletopLiveUnit,
        unit: TabletopGameplayUnit,
        snapshot: TabletopGameplaySnapshot,
        materialProvider: WargusTabletopMaterialProvider?
    ) {
        guard let materialProvider,
              let sprite = snapshot.assets?.sprite(forUnitKind: unit.kind) else { return }
        if sprite.numDirections > 1 {
            // Directional unit: the per-frame camera-relative pass owns the
            // quad texture. Record fresh engine state (facing/frame/owner) and
            // let refreshDirectionalSprites request the matching column.
            liveUnit.setDirectionalSprite(.init(sprite: sprite, unit: unit))
            return
        }
        liveUnit.setDirectionalSprite(nil)
        materialProvider.unitMaterial(unit: unit, sprite: sprite) { [weak liveUnit] material in
            liveUnit?.setSpriteMaterial(material)
        }
    }

    /// Per-frame pass that requests the camera-relative directional sprite for
    /// each unit whose displayed direction changed as the viewer orbited the
    /// board. Cheap when nothing changed: `cameraRelativeSpriteFrame` returns
    /// `nil` for units without a directional sprite or an unchanged frame, and
    /// the provider caches decoded textures.
    @MainActor
    static func refreshDirectionalSprites(
        _ liveUnits: some Sequence<TabletopLiveUnit>,
        viewerAzimuthRadians: Double,
        materialProvider: WargusTabletopMaterialProvider?
    ) {
        guard let materialProvider else { return }
        for liveUnit in liveUnits {
            guard let resolved = liveUnit.cameraRelativeSpriteFrame(
                viewerAzimuthRadians: viewerAzimuthRadians) else { continue }
            materialProvider.unitMaterial(
                unit: resolved.unit, sprite: resolved.sprite,
                frameOverride: resolved.frame, mirrorOverride: resolved.mirror
            ) { [weak liveUnit] material in
                liveUnit?.setSpriteMaterial(material)
            }
        }
    }

    /// Updates terrain tile materials in `tileEntities` for tiles listed in
    /// `changedTiles`. Sets the procedural color immediately, then (when a
    /// material provider + tileset are available) re-requests the real tile art
    /// for the tile's new graphic index so an in-place terrain change (e.g. a
    /// felled tree) reloads real art instead of staying a flat color.
    /// Tiles not present in the dictionary are silently skipped.
    @MainActor
    static func updateTerrainTiles(
        _ changedTiles: [TabletopTerrainTile],
        in tileEntities: [String: ModelEntity],
        tileset: TabletopTilesetInfo? = nil,
        materialProvider: WargusTabletopMaterialProvider? = nil
    ) {
        for tile in changedTiles {
            guard let entity = tileEntities[tileEntityKey(tileX: tile.tileX, tileZ: tile.tileZ)] else { continue }
            entity.model?.materials = [translucentUnlitMaterial(tile.kind.tileColor)]
            if let materialProvider {
                materialProvider.terrainMaterial(
                    graphicIndex: tile.graphicIndex, tileset: tileset
                ) { [weak entity] material in
                    entity?.model?.materials = [material]
                }
            }
        }
    }

    /// Reveals or conceals per-tile fog entities for the tiles listed in
    /// `changedTiles`. The fog quad is disabled (invisible) when a tile is
    /// revealed and enabled (dark overlay) when it becomes hidden again.
    static func updateFogTiles(
        _ changedTiles: [TabletopFogTile],
        in tileEntities: [String: ModelEntity]
    ) {
        for tile in changedTiles {
            guard let entity = tileEntities[fogEntityKey(tileX: tile.tileX, tileZ: tile.tileZ)] else { continue }
            entity.isEnabled = !tile.isRevealed
        }
    }

    /// Stable dictionary key for a terrain `ModelEntity`.
    static func tileEntityKey(tileX: Int, tileZ: Int) -> String { "\(tileX).\(tileZ)" }

    /// Stable dictionary key for a per-tile fog overlay `ModelEntity`.
    static func fogEntityKey(tileX: Int, tileZ: Int) -> String { "fog.\(tileX).\(tileZ)" }
}

