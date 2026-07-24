// tabletop_command_harness_test.swift
//
// Host-Mac unit tests for the opt-in command integration harness state machine
// (TabletopCommandHarness): enablement gating, and the select → move → stop
// sequencing that only advances when it observes the engine's state change in a
// later snapshot (so a pass is genuine round-trip proof). No transport, engine,
// Simulator, or proprietary data required.
//
// Run: ./scripts/test-visionos-tabletop-harness.sh
import Foundation

var checks = 0
var failures = 0

func expect(_ cond: Bool, _ msg: String) {
    checks += 1
    if !cond { failures += 1; FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)) }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    expect(a == b, "\(msg) (got \(a), expected \(b))")
}

// MARK: - Fixtures

func makeUnit(id: String, owner: Int, x: Int, z: Int, selected: Bool = false)
    -> TabletopGameplayUnit {
    TabletopGameplayUnit(id: id, owner: owner, hp: 60, maxHP: 60,
                         facingRadians: 0, tileX: x, tileZ: z, kind: "unit-footman")
}

func makeSnapshot(
    units: [TabletopGameplayUnit], selectedID: String? = nil, size: Int = 8,
    actions: [TabletopEngineAction] = [],
    actionState: TabletopEngineActionState = TabletopEngineActionState()
) -> TabletopGameplaySnapshot {
    TabletopGameplaySnapshot(
        version: TabletopGameplaySnapshot.currentVersion,
        mapSize: TabletopMapSize(width: size, height: size),
        terrain: [], fogMask: [], units: units,
        selection: TabletopGameplaySelection(selectedUnitID: selectedID),
        actions: actions, actionState: actionState)
}

// MARK: - Gating

func testGating() {
    expect(!TabletopCommandHarness.isEnabled(environment: [:]),
           "disabled when env var absent (no automation in production)")
    expect(!TabletopCommandHarness.isEnabled(
        environment: [TabletopCommandHarness.environmentKey: "0"]), "disabled for 0")
    expect(TabletopCommandHarness.isEnabled(
        environment: [TabletopCommandHarness.environmentKey: "1"]), "enabled for 1")
    expect(TabletopCommandHarness.isEnabled(
        environment: [TabletopCommandHarness.environmentKey: "true"]), "enabled for true")
    expect(TabletopCommandHarness.isEnabled(
        environment: [TabletopCommandHarness.environmentKey: "YES"]), "enabled for YES")
}

// MARK: - Happy-path authoritative action round-trip

func testFullRoundTrip() {
    let harness = TabletopCommandHarness()
    let unit = makeUnit(id: "7", owner: 0, x: 3, z: 3)
    let move = TabletopEngineAction(
        id: 0x100, slot: 0, kind: .move, targetKind: .map, text: "Move")
    let submenu = TabletopEngineAction(
        id: 0x200, slot: 5, kind: .submenu, value: 2, text: "Build")
    let rootActions = [move, submenu]

    // 1) First snapshot: harness picks the unit and submits a select.
    var (cmds, reports) = harness.advance(with: makeSnapshot(units: [unit]))
    expectEqual(cmds, [.selectUnit(id: "7")], "first observation submits select")
    expect(reports.isEmpty, "no verdict until the engine reflects the selection")
    expectEqual(harness.phase, .selecting, "still selecting until observed")

    // 2) Engine reflects selection and publishes authoritative root actions.
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [unit], selectedID: "7", actions: rootActions))
    expect(reports.contains(where: { $0.step == "select" && $0.passed }),
           "select verdict passes once engine shows the unit selected")
    expectEqual(cmds, [.activateAction(id: 0x100, slot: 0)],
               "activates the exact engine move slot")
    expectEqual(harness.phase, .activatingTargetForCancel,
               "waits for explicit engine target state")

    // 3) Exact activation enters targeting; first exercise cancellation.
    let pending = TabletopEngineActionState(
        targetKind: .map, targetActionKind: .move,
        targetSlot: 0, targetActionID: 0x100, lastResult: .accepted)
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [unit], selectedID: "7",
                          actions: rootActions, actionState: pending))
    expectEqual(cmds, [.cancelAction], "pending exact action is cancelled")
    expect(reports.contains(where: { $0.step == "activate" && $0.passed }),
           "exact activation is observed")

    // 4) Cancellation clears targeting; activate the same descriptor again.
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [unit], selectedID: "7", actions: rootActions))
    expectEqual(cmds, [.activateAction(id: 0x100, slot: 0)],
               "re-activates exact slot for target submission")
    expect(reports.contains(where: { $0.step == "cancel" && $0.passed }),
           "target cancellation is observed")

    // 5) Pending again: submit an in-bounds board tile.
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [unit], selectedID: "7",
                          actions: rootActions, actionState: pending))
    expectEqual(cmds.count, 1, "submits exactly one target command")
    if case .submitActionTarget(let tx, let tz)? = cmds.first {
        expect((tx, tz) != (3, 3), "target differs from the baseline tile")
        expect(tx >= 0 && tx < 8 && tz >= 0 && tz < 8, "target is in bounds")
    } else {
        expect(false, "expected a submitActionTarget command")
    }

    // 6) Engine movement proves the targeted authoritative action executed.
    let movedUnit = makeUnit(id: "7", owner: 0, x: 4, z: 3)
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [movedUnit], selectedID: "7",
                          actions: rootActions))
    expect(reports.contains(where: { $0.step == "target" && $0.passed }),
           "target verdict passes once the engine repositions the unit")
    expectEqual(cmds, [.activateAction(id: 0x200, slot: 5)],
               "activates a nontrivial submenu through its exact slot")
    expectEqual(harness.phase, .openingNontrivial,
               "waits for authoritative submenu transition")

    // 7) Engine panel level changes; cancel/back returns to the root panel.
    let submenuState = TabletopEngineActionState(panelLevel: 2, lastResult: .accepted)
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [movedUnit], selectedID: "7",
                          actionState: submenuState))
    expectEqual(cmds, [.cancelAction], "submits cancel/back from submenu")
    expect(reports.contains(where: { $0.step == "nontrivial" && $0.passed }),
           "nontrivial submenu activation is observed")

    // 8) Root panel restored: submit legacy stop to preserve old command coverage.
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [movedUnit], selectedID: "7",
                          actions: rootActions))
    expectEqual(cmds, [.stopUnit(id: "7")], "submits stop after action probe")
    expect(reports.contains(where: { $0.step == "back" && $0.passed }),
           "cancel/back transition is observed")

    // 9) An uncorrelated snapshot cannot falsely pass stop.
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [movedUnit], selectedID: "7",
                          actions: rootActions))
    expect(reports.isEmpty, "stop waits for a correlated engine result")
    expectEqual(harness.phase, .stopping, "uncorrelated stop remains pending")

    // 10) Correlated accepted result passes stop + complete.
    let stoppedState = TabletopEngineActionState(
        lastRequestID: 9, lastResult: .accepted)
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [movedUnit], selectedID: "7",
                          actions: rootActions, actionState: stoppedState))
    expect(reports.contains(where: { $0.step == "stop" && $0.passed }), "stop passes")
    expect(reports.contains(where: { $0.step == "complete" && $0.passed }),
           "overall round-trip reported complete")
    expectEqual(harness.phase, .finished, "harness finished")
    expect(harness.isComplete, "isComplete true when finished")

    // 11) Further snapshots are inert.
    (cmds, reports) = harness.advance(with: makeSnapshot(units: [movedUnit]))
    expect(cmds.isEmpty && reports.isEmpty, "finished harness ignores further snapshots")
}

// MARK: - Timeout / failure

func testSelectTimeoutFails() {
    let harness = TabletopCommandHarness(maxSnapshotsPerPhase: 3)
    let unit = makeUnit(id: "7", owner: 0, x: 3, z: 3)
    // First submits select.
    _ = harness.advance(with: makeSnapshot(units: [unit]))
    // Engine never reflects selection: after maxSnapshotsPerPhase, fail.
    var lastReports: [TabletopCommandHarnessReport] = []
    for _ in 0..<3 {
        lastReports = harness.advance(with: makeSnapshot(units: [unit])).reports
    }
    expect(lastReports.contains(where: { $0.step == "select" && !$0.passed }),
           "select fails after timeout without an engine state change")
    expectEqual(harness.phase, .failed, "harness failed on timeout")
}

func testNoUnitTimeoutFails() {
    let harness = TabletopCommandHarness(maxSnapshotsPerPhase: 2)
    var reports: [TabletopCommandHarnessReport] = []
    for _ in 0..<2 {
        reports = harness.advance(with: makeSnapshot(units: [])).reports
    }
    expect(reports.contains(where: { $0.step == "select" && !$0.passed }),
           "fails when no live unit ever appears")
    expectEqual(harness.phase, .failed, "failed with no units")
}

// MARK: - Prefers a mobile unit for the move probe

func testPrefersMobileUnitForMoveProbe() {
    // A base scenario lists a (non-movable) town hall before the workers.
    // The harness must select a mobile unit so the move probe is meaningful.
    let building = TabletopGameplayUnit(id: "hall", owner: 0, hp: 1200, maxHP: 1200,
                                        facingRadians: 0, tileX: 5, tileZ: 5,
                                        kind: "unit-town-hall")
    let worker = TabletopGameplayUnit(id: "peon", owner: 0, hp: 30, maxHP: 30,
                                      facingRadians: 0, tileX: 8, tileZ: 8,
                                      kind: "unit-peon")
    let catalog = TabletopAssetCatalog(unitTypes: [
        "unit-town-hall": TabletopUnitSpriteInfo(
            spritePath: "b.png", frameWidth: 128, frameHeight: 128,
            numDirections: 1, flip: false,
            renderCategory: .building, footprintWidth: 4, footprintHeight: 4),
        "unit-peon": TabletopUnitSpriteInfo(
            spritePath: "p.png", frameWidth: 72, frameHeight: 72,
            numDirections: 5, flip: true, renderCategory: .mobile),
    ])
    let snap = TabletopGameplaySnapshot(
        version: TabletopGameplaySnapshot.currentVersion,
        mapSize: TabletopMapSize(width: 32, height: 32),
        terrain: [], fogMask: [], units: [building, worker],
        selection: TabletopGameplaySelection(), assets: catalog)

    let harness = TabletopCommandHarness()
    let (cmds, _) = harness.advance(with: snap)
    expectEqual(cmds, [.selectUnit(id: "peon")],
                "harness selects the mobile worker, not the building listed first")
}

// MARK: - Runner

@main
struct CommandHarnessTests {
    static func main() {
        testGating()
        testFullRoundTrip()
        testSelectTimeoutFails()
        testNoUnitTimeoutFails()
        testPrefersMobileUnitForMoveProbe()

        if failures == 0 {
            print("PASSED: \(checks)/\(checks) checks")
        } else {
            print("FAILED: \(failures)/\(checks) checks failed")
            exit(1)
        }
    }
}
