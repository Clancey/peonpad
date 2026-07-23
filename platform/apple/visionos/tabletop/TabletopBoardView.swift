// TabletopBoardView.swift
//
// The immersive-space RealityView: wires the right-hand command / left-hand
// board-manipulation gestures through the pure logic in TabletopGestureState,
// subscribes to a TabletopGameplaySource for live/demo state, dispatches
// player intents through a TabletopCommandSink, and applies incremental
// RealityKit diffs from TabletopBoardReconciler without rebuilding the board
// root or breaking active gestures.
//
// Production launch uses LiveTabletopSession (which warns when no transport
// is bound and delivers an empty stream). Tests and previews pass a
// DemoTabletopSession via the designated init.
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
    // MARK: - Session injection

    /// The combined source/sink. @State ensures the session object persists
    /// across SwiftUI re-renders; `_session = State(initialValue:)` in the
    /// designated init lets tests inject a DemoTabletopSession.
    @State private var session: AnyTabletopSession

    /// Production default: LiveTabletopSession with no transport bound.
    /// Logs an error and delivers an empty stream; the board shows a
    /// diagnostic overlay until a transport is connected.
    init() {
        _session = State(initialValue: AnyTabletopSession(LiveTabletopSession(transport: nil)))
    }

    /// Designated init for tests and SwiftUI previews.
    init<S: TabletopGameplaySource & TabletopCommandSink>(
        session: S,
        harnessTransport: TabletopTransport? = nil
    ) where S: Sendable {
        _session = State(initialValue: AnyTabletopSession(session))
        self.harnessTransport = harnessTransport
    }

    /// The production transport, passed through only so the opt-in command
    /// integration harness can submit probes through the exact production
    /// `send(_:)` and observe the results on the same live stream the board
    /// reconciles. `nil` in tests/previews and when no transport is bound.
    private var harnessTransport: TabletopTransport?

    // MARK: - Gesture / board state

    @State private var manipulator = TabletopBoardManipulator(initial: TabletopPlacement.initialTransform)
    @State private var commandReducer = TabletopCommandReducer()

    // MARK: - Snapshot tracking

    /// Most-recently received snapshot. `nil` until the first snapshot arrives
    /// from the source (indicates "no transport" in the live session case).
    @State private var gameplaySnapshot: TabletopGameplaySnapshot? = nil
    @State private var previousSnapshot: TabletopGameplaySnapshot? = nil

    // MARK: - Live entity tracking

    /// RealityKit entities are reference types; capturing them in @State is
    /// safe and avoids rebuilding the board root on every SwiftUI re-render.
    @State private var boardRoot: Entity?
    @State private var headAnchor: Entity?
    /// Unit entities keyed by stable unit ID for O(1) incremental updates.
    @State private var liveUnitsByID: [String: TabletopLiveUnit] = [:]
    /// Terrain tile entities keyed by "tileX.tileZ" for O(1) material updates.
    @State private var tileEntities: [String: ModelEntity] = [:]
    @State private var subscriptions: [EventSubscription] = []

    /// The map→board fit derived from the first snapshot's map size. Scales an
    /// arbitrary engine map onto the fixed physical board.
    @State private var mapFit: TabletopMapFit?

    /// Resolves real Wargus terrain/unit art when a catalog is present;
    /// otherwise the board uses procedural coloring (no proprietary art).
    private let assetResolver: TabletopAssetResolver = WargusTabletopAssetResolver()

    /// Loads real Wargus terrain/unit textures from the staged read-only data
    /// directory at runtime. `nil` when the staged data is absent, so the board
    /// renders fully procedurally rather than silently faking success.
    @State private var materialProvider: WargusTabletopMaterialProvider? =
        WargusTabletopMaterialProvider.make(
            dataPath: PeonPadTabletopLaunch.resolveConfig().dataPath)

    // MARK: - Body

    var body: some View {
        RealityView { content, attachments in
            // -- Board root --
            let root = Entity()
            root.name = "board"
            applyTransform(manipulator.transform, to: root)
            content.add(root)

            // -- Palette attachment (board-relative, not head-locked) --
            if let paletteEntity = attachments.entity(for: TabletopPaletteView.attachmentID) {
                paletteEntity.name = "palette"
                paletteEntity.position = [
                    0,
                    TabletopBoardMetrics.unitHeight * 1.6,
                    TabletopBoardMetrics.halfExtent + 0.08,
                ]
                root.addChild(paletteEntity)
            }

            // -- Head anchor for billboard orientation --
            let head = AnchorEntity(.head)
            head.name = "headAnchor"
            content.add(head)

            self.boardRoot = root
            self.headAnchor = head

            // -- Per-frame billboard update --
            let subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                refreshBillboards()
            }
            subscriptions.append(subscription)

            // Note: terrain surface and unit entities are NOT built here.
            // They are built incrementally when the first snapshot arrives
            // in the .task below, so the same incremental path handles
            // both the initial build and subsequent updates.
        } update: { _, _ in
            // Gesture handlers mutate entities directly (RealityKit's
            // recommended pattern for continuous manipulation). Snapshot-
            // driven changes are applied from the .task subscriber below.
        } attachments: {
            Attachment(id: TabletopPaletteView.attachmentID) {
                TabletopPaletteView(onRecenter: recenter)
            }
        }
        .gesture(
            SpatialEventGesture()
                .onChanged { events in handle(events: events) }
                .onEnded   { events in handle(events: events) }
        )
        // Subscribe to the gameplay source and apply incremental diffs.
        .task {
            for await snapshot in session.snapshots {
                applySnapshotDiff(snapshot)
            }
            // Stream finished without delivering any snapshot: no transport
            // is bound. `gameplaySnapshot` remains nil; the overlay below
            // surfaces the diagnostic to the developer.
        }
        // Opt-in command integration harness (disabled unless
        // PEONPAD_TABLETOP_COMMAND_HARNESS is set): submits select→move→stop
        // through the production transport and logs whether the engine changed
        // state, as observed on the same live stream the board reconciles.
        .task {
            guard let harnessTransport else { return }
            _ = TabletopCommandHarnessDriver.runIfEnabled(transport: harnessTransport)
        }
        // Diagnostic overlay: visible when no snapshot has been received
        // (live session with no transport bound).
        .overlay(alignment: .center) {
            if gameplaySnapshot == nil {
                noTransportOverlay
            }
        }
    }

    // MARK: - No-transport diagnostic

    private var noTransportOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("No engine transport connected")
                .font(.headline)
            Text("Bind a TabletopTransport before launching the production board.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .glassBackgroundEffect()
    }

    // MARK: - Incremental snapshot reconciliation

    /// Computes the diff from the previous snapshot and applies the minimal
    /// set of RealityKit mutations needed to bring the board up to date.
    /// Does not rebuild `boardRoot` or discard active gesture state.
    @MainActor
    private func applySnapshotDiff(_ next: TabletopGameplaySnapshot) {
        guard let boardRoot else { return }

        let diff = TabletopBoardReconciler.diff(from: previousSnapshot, to: next)

        // -- Terrain surface (first snapshot builds the surface fitted to the
        //    real map size; subsequent snapshots only update changed tiles) --
        let fit: TabletopMapFit
        if let existing = mapFit, previousSnapshot != nil {
            fit = existing
        } else {
            fit = TabletopBoardMetrics.fit(for: next)
            mapFit = fit
        }

        if previousSnapshot == nil {
            tileEntities = TabletopBoardBuilder.addSurface(
                to: boardRoot, snapshot: next, fit: fit, resolver: assetResolver,
                materialProvider: materialProvider)
            tabletopEngineLog("[Tabletop] board built from first snapshot: "
                + "map=\(next.mapSize.width)x\(next.mapSize.height) "
                + "tiles=\(tileEntities.count) units=\(next.units.count) "
                + "assets=\(next.assets != nil ? "real" : "procedural")")
        } else {
            TabletopBoardBuilder.updateTerrainTiles(diff.changedTerrainTiles, in: tileEntities)
            TabletopBoardBuilder.updateFogTiles(diff.changedFogTiles, in: tileEntities)
        }

        // -- Units added --
        for unit in diff.addedUnits {
            let live = TabletopBoardBuilder.addUnit(
                unit, to: boardRoot, snapshot: next, fit: fit,
                materialProvider: materialProvider)
            liveUnitsByID[unit.id] = live
        }

        // -- Units updated --
        for unitDiff in diff.updatedUnits {
            guard let live = liveUnitsByID[unitDiff.id],
                  let unit = next.units.first(where: { $0.id == unitDiff.id }) else { continue }

            if unitDiff.positionChanged {
                live.root.position = TabletopBoardMetrics.tileCenter(
                    fit, tileX: unit.tileX, tileZ: unit.tileZ
                )
            }
            if unitDiff.facingChanged {
                live.currentFacingRadians = unit.facingRadians
            }
            if unitDiff.ownerChanged {
                live.updateOwnerTint(TabletopBoardBuilder.ownerTint(owner: unit.owner))
            }
            // Re-crop the real sprite when the engine advanced the animation
            // frame or mirror (or ownership changed the team tint).
            if unitDiff.frameChanged || unitDiff.ownerChanged {
                TabletopBoardBuilder.refreshUnitSprite(
                    live, unit: unit, snapshot: next, materialProvider: materialProvider)
            }
            if unitDiff.hpChanged {
                live.setAlive(unit.isAlive)
            }
            if unitDiff.selectionChanged {
                live.setSelected(next.selection.selectedUnitID == unit.id)
            }
        }

        // -- Units removed --
        for id in diff.removedUnitIDs {
            if let live = liveUnitsByID.removeValue(forKey: id) {
                live.root.removeFromParent()
            }
        }

        previousSnapshot = next
        gameplaySnapshot = next
    }

    // MARK: - Gesture bridging

    private func handle(events: SpatialEventCollection) {
        var leftSample: TabletopGestureSample?
        var rightSample: TabletopGestureSample?

        for event in events {
            guard let sample = makeSample(from: event) else { continue }
            switch sample.chirality {
            case .left:  leftSample = sample
            case .right: rightSample = sample
            }
        }

        // Suppress the right hand from dispatching a gameplay command when
        // both hands are simultaneously active (two-hand board manipulation).
        if let leftSample, let rightSample,
           leftSample.phase == .active, rightSample.phase == .active {
            commandReducer.suppressRightHandID(rightSample.id)
        }

        let transform = manipulator.update(left: leftSample, right: rightSample)
        if let boardRoot {
            applyTransform(transform, to: boardRoot)
        }

        let commandEvent = commandReducer.update(right: rightSample)
        dispatch(commandEvent: commandEvent)
    }

    private func makeSample(from event: SpatialEventCollection.Event) -> TabletopGestureSample? {
        guard event.kind == .directPinch, let chirality = event.chirality else { return nil }

        let mappedChirality: TabletopChirality = (chirality == .left) ? .left : .right
        let mappedPhase: TabletopGesturePhase
        switch event.phase {
        case .active:    mappedPhase = .active
        case .ended:     mappedPhase = .ended
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

    /// Translates a completed right-hand gesture event into a gameplay
    /// command and forwards it to the session sink (rather than mutating
    /// local demo state directly).
    private func dispatch(commandEvent: TabletopRightHandEvent) {
        switch commandEvent {
        case .none:
            return

        case let .tappedEntity(name, _):
            guard name.hasPrefix("unit.") else { return }
            let unitID = String(name.dropFirst("unit.".count))
            session.send(.selectUnit(id: unitID))

        case let .tappedEmpty(boardPoint):
            guard let snapshot = gameplaySnapshot,
                  let selected = snapshot.validatedSelectedUnit,
                  let boardRoot,
                  let fit = mapFit else {
                // Nothing selected and no valid board root: tapping empty space
                // with no unit selected is a no-op (deselectAll with nothing to
                // deselect would redundantly publish an identical snapshot).
                return
            }
            let worldPos = SIMD3<Float>(Float(boardPoint.x), Float(boardPoint.y), Float(boardPoint.z))
            let localPos = boardRoot.convert(position: worldPos, from: nil)
            let target = fit.tile(atX: localPos.x, z: localPos.z)
            // Ignore taps outside the real map bounds.
            guard fit.contains(tileX: target.tileX, tileZ: target.tileZ) else { return }
            session.send(.moveUnit(id: selected.id, toTileX: target.tileX, toTileZ: target.tileZ))
        }
    }

    // MARK: - Per-frame billboard orientation

    private func refreshBillboards() {
        guard let boardRoot, let headAnchor, !liveUnitsByID.isEmpty else { return }
        let headBoardPosition = headAnchor.position(relativeTo: boardRoot)
        let viewerBoardPosition = TabletopPoint3D(
            x: Double(headBoardPosition.x),
            y: 0,
            z: Double(headBoardPosition.z)
        )
        for unit in liveUnitsByID.values {
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

