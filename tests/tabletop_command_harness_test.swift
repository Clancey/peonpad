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
    units: [TabletopGameplayUnit], selectedID: String? = nil, size: Int = 8
) -> TabletopGameplaySnapshot {
    TabletopGameplaySnapshot(
        version: TabletopGameplaySnapshot.currentVersion,
        mapSize: TabletopMapSize(width: size, height: size),
        terrain: [], fogMask: [], units: units,
        selection: TabletopGameplaySelection(selectedUnitID: selectedID))
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

// MARK: - Happy-path select → move → stop

func testFullRoundTrip() {
    let harness = TabletopCommandHarness()
    let unit = makeUnit(id: "7", owner: 0, x: 3, z: 3)

    // 1) First snapshot: harness picks the unit and submits a select.
    var (cmds, reports) = harness.advance(with: makeSnapshot(units: [unit]))
    expectEqual(cmds, [.selectUnit(id: "7")], "first observation submits select")
    expect(reports.isEmpty, "no verdict until the engine reflects the selection")
    expectEqual(harness.phase, .selecting, "still selecting until observed")

    // 2) Engine reflects the selection: harness passes select and submits move.
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [unit], selectedID: "7"))
    expect(reports.contains(where: { $0.step == "select" && $0.passed }),
           "select verdict passes once engine shows the unit selected")
    expectEqual(harness.phase, .moving, "advanced to moving")
    expectEqual(cmds.count, 1, "submits exactly one move command")
    if case .moveUnit(let id, let tx, let tz)? = cmds.first {
        expectEqual(id, "7", "move targets the selected unit")
        expect((tx, tz) != (3, 3), "move target differs from the baseline tile")
        expect(tx >= 0 && tx < 8 && tz >= 0 && tz < 8, "move target in bounds")
    } else {
        expect(false, "expected a moveUnit command")
    }

    // 3) Engine has NOT moved the unit yet: no verdict, keep waiting.
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [unit], selectedID: "7"))
    expect(reports.isEmpty && cmds.isEmpty, "no move verdict until the unit moves")
    expectEqual(harness.phase, .moving, "still moving while unit hasn't moved")

    // 4) Engine moved the unit: pass move, submit stop.
    let movedUnit = makeUnit(id: "7", owner: 0, x: 4, z: 3)
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [movedUnit], selectedID: "7"))
    expect(reports.contains(where: { $0.step == "move" && $0.passed }),
           "move verdict passes once the engine repositions the unit")
    expectEqual(cmds, [.stopUnit(id: "7")], "submits stop after move observed")
    expectEqual(harness.phase, .stopping, "advanced to stopping")

    // 5) Unit still reconciled alive next snapshot: pass stop + complete.
    (cmds, reports) = harness.advance(
        with: makeSnapshot(units: [movedUnit], selectedID: "7"))
    expect(reports.contains(where: { $0.step == "stop" && $0.passed }), "stop passes")
    expect(reports.contains(where: { $0.step == "complete" && $0.passed }),
           "overall round-trip reported complete")
    expectEqual(harness.phase, .finished, "harness finished")
    expect(harness.isComplete, "isComplete true when finished")

    // 6) Further snapshots are inert.
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

// MARK: - Runner

@main
struct CommandHarnessTests {
    static func main() {
        testGating()
        testFullRoundTrip()
        testSelectTimeoutFails()
        testNoUnitTimeoutFails()

        if failures == 0 {
            print("PASSED: \(checks)/\(checks) checks")
        } else {
            print("FAILED: \(failures)/\(checks) checks failed")
            exit(1)
        }
    }
}
