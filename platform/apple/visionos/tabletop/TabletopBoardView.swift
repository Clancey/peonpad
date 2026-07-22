import RealityKit
import SwiftUI
import UIKit

struct TabletopBoardView: View {
    private static let boardName = "PeonPadTabletopBoard"
    private static let markerName = "PeonPadCommandMarker"

    @State private var gestureState = TabletopGestureState()
    @State private var commandCount = 0
    @State private var status = "Pinch the board to begin"
    @State private var commandPoint: TabletopPoint?

    var body: some View {
        RealityView { content, attachments in
            let board = BattlefieldFactory.makeBoard(
                boardName: Self.boardName,
                markerName: Self.markerName
            )
            if let palette = attachments.entity(for: "tabletop-palette") {
                palette.position = [0, 0.16, 0.44]
                board.addChild(palette)
            }
            content.add(board)
        } update: { content, _ in
            guard let board = content.entities.first(where: {
                $0.name == Self.boardName
            }) else {
                return
            }

            let pose = gestureState.boardPose
            board.position = [Float(pose.x), 0, Float(pose.z)]
            board.scale = SIMD3(repeating: Float(pose.scale))

            if let marker = board.findEntity(named: Self.markerName) {
                marker.isEnabled = commandPoint != nil
                if let point = commandPoint {
                    marker.position = [
                        Float(min(max(point.x * 0.001, -0.48), 0.48)),
                        0.055,
                        Float(min(max(point.z * 0.001, -0.30), 0.30))
                    ]
                }
            }
        } attachments: {
            Attachment(id: "tabletop-palette") {
                TabletopPalette(
                    status: status,
                    commandCount: commandCount,
                    scale: gestureState.boardPose.scale,
                    recenter: recenter
                )
            }
        }
        .gesture(
            SpatialEventGesture()
                .onChanged(handleSpatialEvents)
        )
    }

    private func handleSpatialEvents(_ events: SpatialEventCollection) {
        let directPinches = events.compactMap { event
            -> TabletopPinchEvent? in
            guard event.kind == .directPinch,
                  let chirality = event.chirality else {
                return nil
            }

            let hand: TabletopHand
            switch chirality {
            case .left: hand = .left
            case .right: hand = .right
            @unknown default: return nil
            }

            let phase: TabletopPinchPhase
            switch event.phase {
            case .active: phase = .active
            case .ended: phase = .ended
            case .cancelled: phase = .cancelled
            @unknown default: return nil
            }

            return TabletopPinchEvent(
                hand: hand,
                phase: phase,
                point: TabletopPoint(
                    x: Double(event.location3D.x),
                    y: Double(event.location3D.y),
                    z: Double(event.location3D.z)
                )
            )
        }
        .sorted { lhs, rhs in
            lhs.hand < rhs.hand
        }

        for event in directPinches {
            for intent in gestureState.process(event) {
                if case let .commandSelect(point) = intent {
                    commandCount += 1
                    commandPoint = point
                    status = "Right-hand command \(commandCount)"
                }
            }
        }

        if directPinches.allSatisfy({ $0.phase != .active }) {
            status = gestureState.activeHandsDescription
        } else if gestureState.activeHandCount > 0 {
            status = gestureState.activeHandsDescription
        }
    }

    private func recenter() {
        gestureState.recenter()
        commandPoint = nil
        status = "Board recentered"
    }
}

private struct TabletopPalette: View {
    let status: String
    let commandCount: Int
    let scale: Double
    let recenter: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PEONPAD TABLETOP")
                    .font(.caption.bold())
                Text(status)
                    .font(.caption)
                Text("\(commandCount) commands • \(String(format: "%.2f", scale))×")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Recenter", systemImage: "scope", action: recenter)
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .glassBackgroundEffect()
    }
}

@MainActor
private enum BattlefieldFactory {
    static func makeBoard(boardName: String, markerName: String) -> Entity {
        let root = Entity()
        root.name = boardName

        let base = ModelEntity(
            mesh: .generateBox(width: 1.08, height: 0.045, depth: 0.72),
            materials: [material(red: 0.10, green: 0.07, blue: 0.035)]
        )
        base.position.y = -0.015
        base.components.set(InputTargetComponent())
        base.components.set(CollisionComponent(
            shapes: [.generateBox(width: 1.08, height: 0.08, depth: 0.72)]
        ))
        root.addChild(base)

        let columns = 14
        let rows = 9
        let tileWidth: Float = 0.072
        let tileDepth: Float = 0.068
        for row in 0..<rows {
            for column in 0..<columns {
                let isRiver = column == 6 || column == 7
                let isPath = row == 4
                let color: SimpleMaterial
                if isRiver {
                    color = material(red: 0.035, green: 0.25, blue: 0.42)
                } else if isPath {
                    color = material(red: 0.40, green: 0.29, blue: 0.14)
                } else if (row + column).isMultiple(of: 3) {
                    color = material(red: 0.16, green: 0.38, blue: 0.12)
                } else {
                    color = material(red: 0.22, green: 0.48, blue: 0.16)
                }

                let tile = ModelEntity(
                    mesh: .generateBox(
                        width: tileWidth,
                        height: isRiver ? 0.008 : 0.014,
                        depth: tileDepth
                    ),
                    materials: [color]
                )
                tile.position = [
                    (Float(column) - 6.5) * 0.075,
                    isRiver ? 0.010 : 0.018,
                    (Float(row) - 4) * 0.071
                ]
                root.addChild(tile)
            }
        }

        addBridge(to: root)
        addKeeps(to: root)
        addTrees(to: root)

        let marker = ModelEntity(
            mesh: .generateCylinder(height: 0.012, radius: 0.045),
            materials: [material(red: 1.0, green: 0.78, blue: 0.12, metallic: true)]
        )
        marker.name = markerName
        marker.isEnabled = false
        root.addChild(marker)
        return root
    }

    private static func addBridge(to root: Entity) {
        let bridge = ModelEntity(
            mesh: .generateBox(width: 0.16, height: 0.025, depth: 0.085),
            materials: [material(red: 0.48, green: 0.29, blue: 0.10)]
        )
        bridge.position = [0, 0.035, 0]
        root.addChild(bridge)
    }

    private static func addKeeps(to root: Entity) {
        for position: SIMD3<Float> in [[-0.36, 0.07, -0.20], [0.36, 0.07, 0.20]] {
            let keep = ModelEntity(
                mesh: .generateBox(width: 0.13, height: 0.13, depth: 0.13),
                materials: [material(red: 0.43, green: 0.43, blue: 0.46)]
            )
            keep.position = position
            root.addChild(keep)

            for x: Float in [-0.052, 0.052] {
                for z: Float in [-0.052, 0.052] {
                    let tower = ModelEntity(
                        mesh: .generateCylinder(height: 0.17, radius: 0.026),
                        materials: [material(red: 0.56, green: 0.54, blue: 0.52)]
                    )
                    tower.position = position + [x, 0.02, z]
                    root.addChild(tower)
                }
            }
        }
    }

    private static func addTrees(to root: Entity) {
        let positions: [SIMD3<Float>] = [
            [-0.45, 0.06, 0.22], [-0.39, 0.06, 0.27],
            [0.43, 0.06, -0.25], [0.36, 0.06, -0.28],
            [-0.24, 0.06, -0.26], [0.25, 0.06, 0.27]
        ]
        for position in positions {
            let tree = ModelEntity(
                mesh: .generateCone(height: 0.12, radius: 0.045),
                materials: [material(red: 0.05, green: 0.30, blue: 0.08)]
            )
            tree.position = position
            root.addChild(tree)
        }
    }

    private static func material(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        metallic: Bool = false
    ) -> SimpleMaterial {
        SimpleMaterial(
            color: UIColor(red: red, green: green, blue: blue, alpha: 1),
            roughness: metallic ? 0.25 : 0.78,
            isMetallic: metallic
        )
    }
}
