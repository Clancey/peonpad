// TabletopCommandHarness.swift
//
// An opt-in, non-production integration harness that proves the tabletop's
// command path is accepted end-to-end: it submits selection, exact engine-button
// activation, target cancellation/submission, submenu activation, and stop through
// the *exact* production `TabletopTransport.send(_:)` and verifies that the
// engine changed state and that the next reconciled snapshot observed it.
//
// This file holds only the framework-free decision logic (which command to send
// next, and how to judge whether the previous one was accepted by observing the
// live snapshot stream), so it is unit-tested on the host Mac. The thin app-only
// driver (`TabletopCommandHarnessDriver`, in the app target) wires this to the
// real transport and logs the verdicts. Nothing here bypasses the command path.
//
// The harness is disabled unless explicitly enabled via an environment flag, so
// no automation controls are ever active in a normal production launch.
//
// Nothing in this file imports SwiftUI, RealityKit, UIKit, or C interop.
import Foundation

/// One step's verdict from the harness, logged by the driver as evidence.
public struct TabletopCommandHarnessReport: Equatable {
    public var step: String
    public var passed: Bool
    public var detail: String
    public init(step: String, passed: Bool, detail: String) {
        self.step = step
        self.passed = passed
        self.detail = detail
    }
}

/// Drives a fixed authoritative-action probe against the live snapshot stream.
/// It is fed each reconciled `TabletopGameplaySnapshot` and returns the
/// command(s) to submit (through the real transport) plus any verdicts. It only
/// advances when it *observes* the engine's state change in a later snapshot, so
/// a passing run is genuine proof that the command round-tripped.
public final class TabletopCommandHarness {
    /// Enablement flag: the harness runs only when this env var is truthy.
    public static let environmentKey = "PEONPAD_TABLETOP_COMMAND_HARNESS"

    /// Whether the harness is enabled for this launch. False by default so no
    /// automation controls are active in production.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switch environment[environmentKey]?.lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }

    public enum Phase: Equatable {
        case selecting
        case probingHiddenSelection
        case probingEnemyAdditive
        case clearingForEnemyInspection
        case selectingEnemyInspection
        case stoppingEnemy
        case movingEnemy
        case activatingEnemy
        case clearingEnemyInspection
        case restoringOwnedSelection
        case activatingTargetForCancel
        case cancellingTarget
        case activatingTargetForSubmit
        case submittingTarget
        case openingNontrivial
        case closingNontrivial
        case stopping
        case finished
        case failed
    }

    public private(set) var phase: Phase = .selecting
    /// The maximum number of snapshots to wait for a state change before a step
    /// is judged failed (the engine advances several cycles per observed move).
    public let maxSnapshotsPerPhase: Int

    private var targetUnitID: String?
    private var enemyUnitID: String?
    private var baselineTile: (x: Int, z: Int)?
    private var moveTarget: (x: Int, z: Int)?
    private var targetAction: TabletopEngineAction?
    private var nontrivialAction: TabletopEngineAction?
    private var baselinePanelLevel: UInt8 = 0
    private var stopRequestBaseline: UInt64 = 0
    private var adversarialRequestBaseline: UInt64 = 0
    private let runAdversarialSelectionProbe: Bool
    private var waited = 0

    public init(
        maxSnapshotsPerPhase: Int = 600,
        runAdversarialSelectionProbe: Bool = true
    ) {
        self.maxSnapshotsPerPhase = max(1, maxSnapshotsPerPhase)
        self.runAdversarialSelectionProbe = runAdversarialSelectionProbe
    }

    public var isComplete: Bool { phase == .finished || phase == .failed }

    /// Feed the next reconciled snapshot. Returns the command(s) to submit
    /// through the production transport for this observation, plus any verdicts.
    public func advance(
        with snapshot: TabletopGameplaySnapshot
    ) -> (commands: [TabletopGameplayCommand], reports: [TabletopCommandHarnessReport]) {
        switch phase {
        case .finished, .failed:
            return ([], [])

        case .selecting:
            // First observation: choose a live unit and submit a select.
            if targetUnitID == nil {
                guard let unit = pickUnit(in: snapshot) else {
                    // No unit yet — keep waiting for a populated snapshot.
                    waited += 1
                    if waited >= maxSnapshotsPerPhase {
                        phase = .failed
                        return ([], [report("select", false, "no live unit appeared")])
                    }
                    return ([], [])
                }
                targetUnitID = unit.id
                baselineTile = (unit.tileX, unit.tileZ)
                waited = 0
                return ([.selectUnit(id: unit.id)], [])
            }
            // Awaiting the engine to reflect the selection.
            if let id = targetUnitID,
               snapshot.selection.selectedUnitID == id {
                guard let action = pickTargetAction(in: snapshot) else {
                    return timeoutOrWait("action")
                }
                targetAction = action
                waited = 0
                let pass = report("select", true,
                                  "unit \(id) selected in engine snapshot")
                if runAdversarialSelectionProbe {
                    guard let enemy = pickEnemyUnit(in: snapshot) else {
                        return timeoutOrWait("enemy-visible")
                    }
                    enemyUnitID = enemy.id
                    adversarialRequestBaseline = snapshot.actionState.lastRequestID
                    phase = .probingHiddenSelection
                    return ([.selectUnit(id: String(UInt32.max - 1))], [pass])
                }
                phase = .activatingTargetForCancel
                return ([.activateAction(id: action.id, slot: action.slot)], [pass])
            }
            return timeoutOrWait("select")

        case .probingHiddenSelection:
            guard let ownID = targetUnitID else {
                return fail("hidden-select", "missing owned unit")
            }
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .rejectedUnitNotFound,
                      snapshot.selection.selectedUnitID == ownID else {
                    return fail("hidden-select",
                                "inaccessible id changed selection or leaked a result")
                }
                guard let enemyID = enemyUnitID else {
                    return fail("enemy-additive", "missing visible enemy")
                }
                adversarialRequestBaseline = snapshot.actionState.lastRequestID
                phase = .probingEnemyAdditive
                waited = 0
                return ([.selectUnit(id: enemyID)], [
                    report("hidden-select", true,
                           "inaccessible id rejected without changing selection"),
                ])
            }
            return timeoutOrWait("hidden-select")

        case .probingEnemyAdditive:
            guard let ownID = targetUnitID else {
                return fail("enemy-additive", "missing owned unit")
            }
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .rejectedUnitNotFound,
                      snapshot.selection.selectedUnitID == ownID else {
                    return fail("enemy-additive",
                                "enemy was mixed into the owned selection")
                }
                adversarialRequestBaseline = snapshot.actionState.lastRequestID
                phase = .clearingForEnemyInspection
                waited = 0
                return ([.deselectAll], [
                    report("enemy-additive", true,
                           "visible enemy could not join an owned selection"),
                ])
            }
            return timeoutOrWait("enemy-additive")

        case .clearingForEnemyInspection:
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .accepted,
                      snapshot.selection.selectedUnitID == nil,
                      snapshot.actionState.panelLevel == 0,
                      !snapshot.actionState.isAwaitingBoardTarget else {
                    return fail("selection-reset",
                                "deselect did not clear panel and target state")
                }
                guard let enemyID = enemyUnitID else {
                    return fail("enemy-inspect", "missing visible enemy")
                }
                adversarialRequestBaseline = snapshot.actionState.lastRequestID
                phase = .selectingEnemyInspection
                waited = 0
                return ([.selectUnit(id: enemyID)], [
                    report("selection-reset", true,
                           "deselect reset target and submenu state"),
                ])
            }
            return timeoutOrWait("selection-reset")

        case .selectingEnemyInspection:
            guard let enemyID = enemyUnitID else {
                return fail("enemy-inspect", "missing visible enemy")
            }
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .accepted,
                      snapshot.selection.selectedUnitID == enemyID else {
                    return fail("enemy-inspect",
                                "visible enemy inspection selection was not reflected")
                }
                adversarialRequestBaseline = snapshot.actionState.lastRequestID
                phase = .stoppingEnemy
                waited = 0
                return ([.stopUnit(id: enemyID)], [
                    report("enemy-inspect", true,
                           "visible enemy can be inspected without command authority"),
                ])
            }
            return timeoutOrWait("enemy-inspect")

        case .stoppingEnemy:
            guard let enemyID = enemyUnitID else {
                return fail("enemy-stop", "missing visible enemy")
            }
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .rejectedUnitNotFound,
                      snapshot.selection.selectedUnitID == enemyID else {
                    return fail("enemy-stop", "enemy stop was not rejected")
                }
                let enemy = snapshot.units.first(where: { $0.id == enemyID })
                adversarialRequestBaseline = snapshot.actionState.lastRequestID
                phase = .movingEnemy
                waited = 0
                return ([.moveUnit(
                    id: enemyID,
                    toTileX: enemy?.tileX ?? 0,
                    toTileZ: enemy?.tileZ ?? 0
                )], [
                    report("enemy-stop", true,
                           "enemy stop rejected through the production queue"),
                ])
            }
            return timeoutOrWait("enemy-stop")

        case .movingEnemy:
            guard let enemyID = enemyUnitID, let action = targetAction else {
                return fail("enemy-move", "missing adversarial fixture")
            }
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .rejectedUnitNotFound,
                      snapshot.selection.selectedUnitID == enemyID else {
                    return fail("enemy-move", "enemy move was not rejected")
                }
                adversarialRequestBaseline = snapshot.actionState.lastRequestID
                phase = .activatingEnemy
                waited = 0
                return ([.activateAction(id: action.id, slot: action.slot)], [
                    report("enemy-move", true,
                           "enemy move rejected through the production queue"),
                ])
            }
            return timeoutOrWait("enemy-move")

        case .activatingEnemy:
            guard let enemyID = enemyUnitID else {
                return fail("enemy-action", "missing visible enemy")
            }
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .rejectedUnitNotFound,
                      snapshot.selection.selectedUnitID == enemyID,
                      !snapshot.actionState.isAwaitingBoardTarget else {
                    return fail("enemy-action",
                                "enemy exact action was not rejected")
                }
                adversarialRequestBaseline = snapshot.actionState.lastRequestID
                phase = .clearingEnemyInspection
                waited = 0
                return ([.deselectAll], [
                    report("enemy-action", true,
                           "enemy exact action rejected before dispatch"),
                ])
            }
            return timeoutOrWait("enemy-action")

        case .clearingEnemyInspection:
            guard let ownID = targetUnitID else {
                return fail("restore-selection", "missing owned unit")
            }
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .accepted,
                      snapshot.selection.selectedUnitID == nil else {
                    return fail("restore-selection",
                                "enemy inspection did not clear")
                }
                adversarialRequestBaseline = snapshot.actionState.lastRequestID
                phase = .restoringOwnedSelection
                waited = 0
                return ([.selectUnit(id: ownID)], [])
            }
            return timeoutOrWait("restore-selection")

        case .restoringOwnedSelection:
            guard let ownID = targetUnitID else {
                return fail("restore-selection", "missing owned unit")
            }
            if snapshot.actionState.lastRequestID != adversarialRequestBaseline {
                guard snapshot.actionState.lastResult == .accepted,
                      snapshot.selection.selectedUnitID == ownID,
                      let action = pickTargetAction(in: snapshot) else {
                    return fail("restore-selection",
                                "owned selection or actions were not restored")
                }
                targetAction = action
                phase = .activatingTargetForCancel
                waited = 0
                return ([.activateAction(id: action.id, slot: action.slot)], [
                    report("restore-selection", true,
                           "owned selection restored after adversarial probes"),
                ])
            }
            return timeoutOrWait("restore-selection")

        case .activatingTargetForCancel:
            guard let action = targetAction else {
                phase = .failed
                return ([], [report("action", false, "missing exact target action")])
            }
            if snapshot.actionState.targetActionID == action.id,
               snapshot.actionState.targetSlot == action.slot,
               snapshot.actionState.isAwaitingBoardTarget {
                phase = .cancellingTarget
                waited = 0
                return ([.cancelAction], [
                    report("activate", true,
                           "exact slot \(action.slot) entered \(action.targetKind) targeting"),
                ])
            }
            return timeoutOrWait("activate")

        case .cancellingTarget:
            guard let action = targetAction else {
                phase = .failed
                return ([], [report("cancel", false, "missing exact target action")])
            }
            if !snapshot.actionState.isAwaitingBoardTarget {
                phase = .activatingTargetForSubmit
                waited = 0
                return ([.activateAction(id: action.id, slot: action.slot)], [
                    report("cancel", true, "engine target state cleared"),
                ])
            }
            return timeoutOrWait("cancel")

        case .activatingTargetForSubmit:
            guard let action = targetAction else {
                phase = .failed
                return ([], [report("target", false, "missing exact target action")])
            }
            if snapshot.actionState.targetActionID == action.id,
               snapshot.actionState.targetSlot == action.slot,
               snapshot.actionState.isAwaitingBoardTarget {
                let target = chooseMoveTarget(in: snapshot)
                moveTarget = target
                phase = .submittingTarget
                waited = 0
                return ([.submitActionTarget(tileX: target.x, tileZ: target.z)], [])
            }
            return timeoutOrWait("target")

        case .submittingTarget:
            guard let id = targetUnitID, let baseline = baselineTile else {
                phase = .failed
                return ([], [report("target", false, "missing movement baseline")])
            }
            if let unit = snapshot.units.first(where: { $0.id == id }) {
                let moved = unit.tileX != baseline.x || unit.tileZ != baseline.z
                if moved {
                    guard let action = pickNontrivialAction(in: snapshot) else {
                        return timeoutOrWait("nontrivial")
                    }
                    nontrivialAction = action
                    baselinePanelLevel = snapshot.actionState.panelLevel
                    phase = .openingNontrivial
                    waited = 0
                    let pass = report("target", true,
                        "exact action target moved unit \(id) to "
                        + "(\(unit.tileX),\(unit.tileZ)) from "
                        + "(\(baseline.x),\(baseline.z))")
                    return ([.activateAction(id: action.id, slot: action.slot)], [pass])
                }
            }
            return timeoutOrWait("target")

        case .openingNontrivial:
            guard let action = nontrivialAction else {
                phase = .failed
                return ([], [report("nontrivial", false, "missing submenu action")])
            }
            if snapshot.actionState.panelLevel != baselinePanelLevel {
                phase = .closingNontrivial
                waited = 0
                return ([.cancelAction], [
                    report("nontrivial", true,
                           "exact submenu slot \(action.slot) opened panel "
                           + "\(snapshot.actionState.panelLevel)"),
                ])
            }
            return timeoutOrWait("nontrivial")

        case .closingNontrivial:
            guard let id = targetUnitID else {
                phase = .failed
                return ([], [report("back", false, "missing selected unit")])
            }
            if snapshot.actionState.panelLevel == 0,
               !snapshot.actionState.isAwaitingBoardTarget {
                phase = .stopping
                waited = 0
                stopRequestBaseline = snapshot.actionState.lastRequestID
                return ([.stopUnit(id: id)], [
                    report("back", true, "cancel/back restored root action panel"),
                ])
            }
            return timeoutOrWait("back")

        case .stopping:
            guard let id = targetUnitID else {
                phase = .failed
                return ([], [report("stop", false, "missing target state")])
            }
            if snapshot.actionState.lastRequestID != stopRequestBaseline {
                guard snapshot.actionState.lastResult == .accepted else {
                    phase = .failed
                    return ([], [
                        report("stop", false,
                               "engine rejected stop: \(snapshot.actionState.lastResult)"),
                    ])
                }
                guard snapshot.units.contains(where: { $0.id == id && $0.isAlive }) else {
                    phase = .failed
                    return ([], [report("stop", false, "stopped unit disappeared")])
                }
                phase = .finished
                return ([], [
                    report("stop", true, "unit \(id) stopped and still reconciled"),
                    report("complete", true,
                           "selection+exact-action+target/cancel+submenu+stop observed"),
                ])
            }
            return timeoutOrWait("stop")
        }
    }

    // MARK: - Helpers

    private func pickTargetAction(
        in snapshot: TabletopGameplaySnapshot
    ) -> TabletopEngineAction? {
        let available = snapshot.actions.filter {
            $0.isVisible && $0.isEnabled && $0.targetKind == .map
        }
        return available.first(where: { $0.kind == .move }) ?? available.first
    }

    private func pickNontrivialAction(
        in snapshot: TabletopGameplaySnapshot
    ) -> TabletopEngineAction? {
        snapshot.actions.first(where: {
            $0.isVisible && $0.isEnabled && $0.kind == .submenu
        })
    }

    private func pickEnemyUnit(
        in snapshot: TabletopGameplaySnapshot
    ) -> TabletopGameplayUnit? {
        guard let ownID = targetUnitID,
              let own = snapshot.units.first(where: { $0.id == ownID }) else {
            return nil
        }
        return snapshot.units.first(where: {
            $0.isAlive && $0.owner != own.owner && $0.owner != 15
        })
    }

    /// Prefer a unit owned by the local player (owner 0), else any live unit.
    private func pickUnit(in snapshot: TabletopGameplaySnapshot) -> TabletopGameplayUnit? {
        let live = snapshot.units.filter { $0.isAlive }
        // Prefer a *mobile* own unit: buildings/resources can't move, so
        // selecting one (they are often listed first in a base scenario) would
        // make the move probe a meaningless no-op. When no asset catalog is
        // present (procedural/demo snapshots) every unit is treated as mobile.
        func isMobile(_ u: TabletopGameplayUnit) -> Bool {
            guard let sprite = snapshot.assets?.sprite(forUnitKind: u.kind) else { return true }
            return sprite.renderCategory == .mobile
        }
        return live.first(where: { $0.owner == 0 && isMobile($0) })
            ?? live.first(where: { isMobile($0) })
            ?? live.first(where: { $0.owner == 0 })
            ?? live.first
    }

    /// A deterministic in-bounds neighbor tile to move to (prefers +x, then -x,
    /// then +z, then -z), different from the baseline tile.
    private func chooseMoveTarget(in snapshot: TabletopGameplaySnapshot) -> (x: Int, z: Int) {
        let base = baselineTile ?? (0, 0)
        let w = snapshot.mapSize.width
        let h = snapshot.mapSize.height
        let candidates = [
            (base.x + 1, base.z), (base.x - 1, base.z),
            (base.x, base.z + 1), (base.x, base.z - 1),
        ]
        for c in candidates where c.0 >= 0 && c.0 < w && c.1 >= 0 && c.1 < h {
            return (c.0, c.1)
        }
        return base
    }

    private func timeoutOrWait(
        _ step: String
    ) -> (commands: [TabletopGameplayCommand], reports: [TabletopCommandHarnessReport]) {
        waited += 1
        if waited >= maxSnapshotsPerPhase {
            phase = .failed
            return ([], [report(step, false, "no engine state change within "
                                 + "\(maxSnapshotsPerPhase) snapshots")])
        }
        return ([], [])
    }

    private func fail(
        _ step: String,
        _ detail: String
    ) -> (commands: [TabletopGameplayCommand], reports: [TabletopCommandHarnessReport]) {
        phase = .failed
        return ([], [report(step, false, detail)])
    }

    private func report(_ step: String, _ passed: Bool, _ detail: String)
        -> TabletopCommandHarnessReport {
        TabletopCommandHarnessReport(step: step, passed: passed, detail: detail)
    }
}

// MARK: - Driver

/// Wires `TabletopCommandHarness` to a live `TabletopTransport`. When enabled,
/// it subscribes to the *production* snapshot stream and submits each probe
/// command through the *production* `send(_:)`, logging PASS/FAIL verdicts as
/// evidence. Disabled by default so no automation runs in production.
public enum TabletopCommandHarnessDriver {
    /// Starts the harness against `transport` when the environment flag is set,
    /// returning the running `Task` (or `nil` when disabled). The task ends when
    /// the probe finishes or is cancelled.
    @discardableResult
    public static func runIfEnabled(
        transport: TabletopTransport,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    ) -> Task<Void, Never>? {
        guard TabletopCommandHarness.isEnabled(environment: environment) else { return nil }
        log("[TabletopHarness] enabled — probing authoritative actions through the "
            + "production transport (opt-in, non-production).")
        return Task {
            let harness = TabletopCommandHarness()
            for await snapshot in transport.snapshots {
                if Task.isCancelled { break }
                let (commands, reports) = harness.advance(with: snapshot)
                for r in reports {
                    log("[TabletopHarness] \(r.passed ? "PASS" : "FAIL") "
                        + "\(r.step): \(r.detail)")
                }
                for command in commands {
                    await transport.send(command)
                }
                if harness.isComplete {
                    log("[TabletopHarness] complete — phase=\(harness.phase)")
                    break
                }
            }
        }
    }
}
