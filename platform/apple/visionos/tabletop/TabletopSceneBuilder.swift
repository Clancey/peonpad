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
}

enum TabletopBoardMetrics {
    /// Board is a square grid of tiles, in meters.
    static let tileSize: Float = 0.12
    static let tileCountPerSide = 7
    static var boardExtent: Float { tileSize * Float(tileCountPerSide) }
    static var halfExtent: Float { boardExtent / 2 }

    static let unitHeight: Float = 0.16
    static let unitRadius: Float = 0.03

    /// World-space position (relative to the board root) of the center of
    /// tile (tileX, tileZ), with (0, 0) at the board's own center.
    static func tileCenter(tileX: Int, tileZ: Int) -> SIMD3<Float> {
        SIMD3<Float>(Float(tileX) * tileSize, 0, Float(tileZ) * tileSize)
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
    let baseMaterial: UnlitMaterial
    let mirroredMaterial: UnlitMaterial

    init(spec: TabletopUnitSpec) {
        self.spec = spec

        let root = Entity()
        root.name = "unit.\(spec.id)"
        root.position = TabletopBoardMetrics.tileCenter(tileX: spec.tileX, tileZ: spec.tileZ)
        root.components.set(InputTargetComponent())
        root.components.set(
            CollisionComponent(shapes: [
                .generateBox(size: SIMD3<Float>(
                    TabletopBoardMetrics.unitRadius * 2.2,
                    TabletopBoardMetrics.unitHeight,
                    TabletopBoardMetrics.unitRadius * 2.2
                ))
                .offsetBy(translation: [0, TabletopBoardMetrics.unitHeight / 2, 0])
            ])
        )
        root.components.set(HoverEffectComponent())

        let body = ModelEntity(
            mesh: .generateCylinder(height: TabletopBoardMetrics.unitHeight, radius: TabletopBoardMetrics.unitRadius),
            materials: [translucentUnlitMaterial(spec.tint.withAlphaComponent(0.22))]
        )
        body.name = root.name + ".body"
        body.position = [0, TabletopBoardMetrics.unitHeight / 2, 0]
        root.addChild(body)

        let quad = ModelEntity(
            mesh: .generatePlane(width: TabletopBoardMetrics.unitRadius * 1.7, height: TabletopBoardMetrics.unitHeight * 0.85),
            materials: [translucentUnlitMaterial(spec.tint)]
        )
        quad.name = root.name + ".quad"
        quad.position = [0, TabletopBoardMetrics.unitHeight / 2, 0]
        root.addChild(quad)

        self.root = root
        self.quad = quad
        self.baseMaterial = translucentUnlitMaterial(spec.tint)
        self.mirroredMaterial = translucentUnlitMaterial(spec.tint.withAlphaComponent(0.85))
    }

    /// Highlights or un-highlights this unit to give visible feedback for
    /// the right-hand selection command intent.
    func setSelected(_ selected: Bool) {
        let alpha: CGFloat = selected ? 1.0 : 0.22
        (quad.model?.materials).map { _ in
            quad.model?.materials = [translucentUnlitMaterial(spec.tint.withAlphaComponent(alpha))]
        }
        if let body = root.findEntity(named: root.name + ".body") as? ModelEntity {
            body.model?.materials = [translucentUnlitMaterial(spec.tint.withAlphaComponent(selected ? 0.5 : 0.22))]
        }
    }

    /// Applies this frame's directional-frame resolution: rotates the quad
    /// to face the viewer around the board's vertical normal, mirrors it
    /// horizontally when the resolved canonical facing requires it, and
    /// tints it to make the selected canonical direction legible even
    /// without real sprite art.
    func applyDirectionalFrame(viewerBoardPosition: TabletopPoint3D, boardRoot: Entity) {
        let unitBoardPosition = TabletopPoint3D(
            x: Double(root.position(relativeTo: boardRoot).x),
            y: 0,
            z: Double(root.position(relativeTo: boardRoot).z)
        )
        let viewerAzimuth = TabletopViewerAzimuth.aroundBoardCenter(viewerBoardPosition: viewerBoardPosition)
        let resolution = TabletopDirectionalFrame.resolve(
            unitFacingRadians: spec.facingRadians,
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

        // Mirroring is represented procedurally (no sprite art is embedded):
        // a horizontally-flipped scale plus a dimmer tint stands in for
        // "this canonical frame is being mirrored", while the hue always
        // reflects the resolved canonical direction.
        let canonicalHue = TabletopTestRoster.canonicalTint(resolution.canonical, base: spec.tint)
        quad.scale.x = resolution.mirrored ? -abs(quad.scale.x) : abs(quad.scale.x)
        quad.model?.materials = [translucentUnlitMaterial(canonicalHue)]
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

enum TabletopBoardBuilder {
    /// Builds the static board surface: a checkerboard grid of tiles plus a
    /// translucent fog-of-war plane sitting just above it. Both stay glued
    /// to the board plane because they are children of `boardRoot`.
    static func addSurface(to boardRoot: Entity) {
        let half = TabletopBoardMetrics.tileCountPerSide / 2
        for tileZ in -half...half {
            for tileX in -half...half {
                let tile = ModelEntity(
                    mesh: .generatePlane(
                        width: TabletopBoardMetrics.tileSize * 0.96,
                        depth: TabletopBoardMetrics.tileSize * 0.96
                    ),
                    materials: [translucentUnlitMaterial((tileX + tileZ).isMultiple(of: 2) ? UIColor(white: 0.70, alpha: 1) : UIColor(white: 0.18, alpha: 1))]
                )
                tile.name = "board.tile.\(tileX).\(tileZ)"
                tile.position = TabletopBoardMetrics.tileCenter(tileX: tileX, tileZ: tileZ)
                boardRoot.addChild(tile)
            }
        }

        let fog = ModelEntity(
            mesh: .generatePlane(
                width: TabletopBoardMetrics.boardExtent * 1.02,
                depth: TabletopBoardMetrics.boardExtent * 1.02
            ),
            materials: [translucentUnlitMaterial(UIColor(white: 0.85, alpha: 0.12))]
        )
        fog.name = "board.fog"
        fog.position = [0, 0.01, 0]
        boardRoot.addChild(fog)
    }

    static func addUnits(to boardRoot: Entity) -> [TabletopLiveUnit] {
        TabletopTestRoster.units.map { spec in
            let unit = TabletopLiveUnit(spec: spec)
            boardRoot.addChild(unit.root)
            return unit
        }
    }
}
