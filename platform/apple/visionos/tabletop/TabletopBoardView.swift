// TabletopBoardView.swift
//
// The immersive-space RealityView: builds the board once, wires the
// right-hand command / left-hand board-manipulation gestures through the
// pure logic in TabletopGestureState.swift, and re-orients every unit's
// billboard each frame so it always faces the viewer while preserving the
// unit's true world-space facing.
import RealityKit
import SwiftUI
import Spatial
import UIKit

/// Where the board first appears, and how far in front of the viewer
/// "Recenter" places it again.
private enum TabletopPlacement {
    static let initialTransform = TabletopBoardTransform(
        position: TabletopPoint3D(x: 0, y: 1.1, z: -1.15),
        yawRadians: 0,
        scale: 1
    )
    static let recenterDistance: Double = 1.15
    static let recenterHeight: Double = 1.1
}

struct TabletopBoardView: View {
    @State private var manipulator = TabletopBoardManipulator(initial: TabletopPlacement.initialTransform)
    @State private var commandReducer = TabletopCommandReducer()
    @State private var gameplaySnapshot = TabletopGameplaySnapshot.demo()
    @State private var subscriptions: [EventSubscription] = []

    // Populated once in `make` and reused by the gesture handlers and the
    // per-frame update closure; RealityKit entities are reference types, so
    // capturing them here is safe and avoids rebuilding the board every time
    // SwiftUI re-evaluates the view body.
    @State private var boardRoot: Entity?
    @State private var headAnchor: Entity?
    @State private var liveUnits: [TabletopLiveUnit] = []

    var body: some View {
        RealityView { content, attachments in
            let boardRoot = Entity()
            boardRoot.name = "board"
            applyTransform(manipulator.transform, to: boardRoot)
            content.add(boardRoot)

            TabletopBoardBuilder.addSurface(to: boardRoot, snapshot: gameplaySnapshot)
            let units = TabletopBoardBuilder.addUnits(to: boardRoot, snapshot: gameplaySnapshot)

            if let paletteEntity = attachments.entity(for: TabletopPaletteView.attachmentID) {
                paletteEntity.name = "palette"
                paletteEntity.position = [
                    0,
                    TabletopBoardMetrics.unitHeight * 1.6,
                    TabletopBoardMetrics.halfExtent + 0.08,
                ]
                boardRoot.addChild(paletteEntity)
            }

            let head = AnchorEntity(.head)
            head.name = "headAnchor"
            content.add(head)

            self.boardRoot = boardRoot
            self.headAnchor = head
            self.liveUnits = units

            let subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                refreshBillboards()
            }
            subscriptions.append(subscription)
        } update: { _, _ in
            // Gesture handlers below mutate entities directly (RealityKit's
            // recommended pattern for continuous manipulation), so this
            // closure intentionally has nothing to reconcile per SwiftUI
            // state change.
        } attachments: {
            Attachment(id: TabletopPaletteView.attachmentID) {
                TabletopPaletteView(onRecenter: recenter)
            }
        }
        .gesture(
            SpatialEventGesture()
                .onChanged { events in
                    handle(events: events)
                }
                .onEnded { events in
                    handle(events: events)
                }
        )
    }

    // MARK: - Gesture bridging (SwiftUI SpatialEventCollection -> pure logic)

    private func handle(events: SpatialEventCollection) {
        var leftSample: TabletopGestureSample?
        var rightSample: TabletopGestureSample?

        for event in events {
            guard let sample = makeSample(from: event) else { continue }
            switch sample.chirality {
            case .left: leftSample = sample
            case .right: rightSample = sample
            }
        }

        // When both hands are simultaneously active, the right hand is part
        // of a two-hand board-manipulation gesture. Mark its event ID for
        // suppression so that a staggered release (left hand drops first,
        // right hand ends later) cannot accidentally dispatch a gameplay
        // command from what was never a selection intent.
        if let leftSample, let rightSample,
           leftSample.phase == .active, rightSample.phase == .active {
            commandReducer.suppressRightHandID(rightSample.id)
        }

        let transform = manipulator.update(left: leftSample, right: rightSample)
        if let boardRoot {
            applyTransform(transform, to: boardRoot)
        }

        let commandEvent = commandReducer.update(right: rightSample)
        apply(commandEvent: commandEvent)
    }

    private func makeSample(from event: SpatialEventCollection.Event) -> TabletopGestureSample? {
        guard event.kind == .directPinch, let chirality = event.chirality else {
            return nil
        }

        let mappedChirality: TabletopChirality = (chirality == .left) ? .left : .right
        let mappedPhase: TabletopGesturePhase
        switch event.phase {
        case .active: mappedPhase = .active
        case .ended: mappedPhase = .ended
        case .cancelled: mappedPhase = .cancelled
        @unknown default: mappedPhase = .cancelled
        }

        let location = event.location3D
        let point = TabletopPoint3D(x: location.x, y: location.y, z: location.z)
        let azimuth = event.inputDevicePose?.azimuth.radians ?? 0

        return TabletopGestureSample(
            id: event.id.hashValue,
            chirality: mappedChirality,
            kind: .directPinch,
            phase: mappedPhase,
            location3D: point,
            poseAzimuthRadians: azimuth,
            targetedEntityName: event.targetedEntity?.name
        )
    }

    private func apply(commandEvent: TabletopRightHandEvent) {
        switch commandEvent {
        case .none:
            return
        case let .tappedEntity(name, _):
            // Entity names follow the "unit.<id>" convention where <id> is
            // the full unit ID (e.g. "unit.sentry.north"). Strip the prefix
            // to recover the stable unit ID used by the gameplay snapshot.
            guard name.hasPrefix("unit.") else { return }
            let unitID = String(name.dropFirst("unit.".count))
            applyGameplayCommand(.selectUnit(id: unitID))
        case let .tappedEmpty(boardPoint):
            if let selected = gameplaySnapshot.validatedSelectedUnit,
               let boardRoot {
                // `boardPoint` is in world space (the RealityView's coordinate
                // space); tile indices are board-local. Convert before dividing
                // so the move lands on the tile the user actually tapped even
                // after the board has been translated, rotated, or scaled.
                let worldPos = SIMD3<Float>(
                    Float(boardPoint.x),
                    Float(boardPoint.y),
                    Float(boardPoint.z)
                )
                let localPos = boardRoot.convert(position: worldPos, from: nil)
                let tileX = Int((Double(localPos.x) / Double(TabletopBoardMetrics.tileSize)).rounded())
                let tileZ = Int((Double(localPos.z) / Double(TabletopBoardMetrics.tileSize)).rounded())
                applyGameplayCommand(.moveUnit(id: selected.id, toTileX: tileX, toTileZ: tileZ))
            } else {
                applyGameplayCommand(.deselectAll)
            }
        }
    }

    /// Applies a gameplay command to the snapshot and reconciles live unit
    /// entities to reflect the new state.
    private func applyGameplayCommand(_ command: TabletopGameplayCommand) {
        let newSnapshot = TabletopGameplayCommandReducer.reduce(gameplaySnapshot, command: command)
        guard newSnapshot != gameplaySnapshot else { return }
        gameplaySnapshot = newSnapshot
        reconcileSnapshot()
    }

    /// Synchronises live RealityKit entities to the current gameplay snapshot:
    /// updates unit board positions and highlights the selected unit.
    private func reconcileSnapshot() {
        for liveUnit in liveUnits {
            let unitID = liveUnit.spec.id
            if let snapUnit = gameplaySnapshot.units.first(where: { $0.id == unitID }) {
                liveUnit.root.position = TabletopBoardMetrics.tileCenter(
                    tileX: snapUnit.tileX, tileZ: snapUnit.tileZ
                )
            }
            liveUnit.setSelected(gameplaySnapshot.selection.selectedUnitID == unitID)
        }
    }

    // MARK: - Per-frame billboard orientation

    private func refreshBillboards() {
        guard let boardRoot, let headAnchor, !liveUnits.isEmpty else { return }
        let headBoardPosition = headAnchor.position(relativeTo: boardRoot)
        let viewerBoardPosition = TabletopPoint3D(
            x: Double(headBoardPosition.x),
            y: 0,
            z: Double(headBoardPosition.z)
        )
        for unit in liveUnits {
            unit.applyDirectionalFrame(viewerBoardPosition: viewerBoardPosition, boardRoot: boardRoot)
        }
    }

    // MARK: - Recenter

    private func recenter() {
        guard let headAnchor, let boardRoot else { return }
        let headWorldPosition = headAnchor.position(relativeTo: nil)
        let headForwardWorld = headAnchor.convert(position: [0, 0, -1], to: nil) - headWorldPosition
        let forwardXZ = SIMD2<Float>(headForwardWorld.x, headForwardWorld.z)
        let forwardLength = forwardXZ == .zero ? 1 : max(forwardXZ.length, 0.0001)
        let forwardNormalized = forwardXZ / forwardLength

        let newPosition = TabletopPoint3D(
            x: Double(headWorldPosition.x + forwardNormalized.x * Float(TabletopPlacement.recenterDistance)),
            y: TabletopPlacement.recenterHeight,
            z: Double(headWorldPosition.z + forwardNormalized.y * Float(TabletopPlacement.recenterDistance))
        )
        // Board's front edge should face back toward the viewer, i.e. the
        // yaw is the opposite of the direction the viewer is facing.
        let newTransform = TabletopBoardTransform(
            position: newPosition,
            yawRadians: atan2(Double(-forwardNormalized.x), Double(-forwardNormalized.y)),
            scale: manipulator.transform.scale
        )
        manipulator = TabletopBoardManipulator(initial: newTransform)
        applyTransform(newTransform, to: boardRoot)
    }

    private func applyTransform(_ transform: TabletopBoardTransform, to entity: Entity) {
        entity.position = SIMD3<Float>(
            Float(transform.position.x),
            Float(transform.position.y),
            Float(transform.position.z)
        )
        entity.orientation = simd_quatf(angle: Float(transform.yawRadians), axis: [0, 1, 0])
        entity.scale = SIMD3<Float>(repeating: Float(transform.scale))
    }
}

private extension SIMD2 where Scalar == Float {
    var length: Float { (x * x + y * y).squareRoot() }
}
