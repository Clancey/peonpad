// tabletop_action_panel_test.swift
//
// Standalone unit tests for the pure floating-action-panel model in
// platform/apple/visionos/tabletop/TabletopActionPanel.swift. No dependency on
// SwiftUI, RealityKit, or the visionOS SDK, so it compiles and runs on the host
// Mac:
//
//   ./scripts/test-visionos-tabletop-action-panel.sh
//
// Covers: action enablement vs. selection, exact command forwarding, the
// move affordance carrying no command, dead-selection safety, and the
// engine-ident → readable-name mapping.
import Foundation

private var failureCount = 0
private var checkCount = 0

private func expect(
    _ condition: @autoclosure () -> Bool, _ message: String,
    file: StaticString = #file, line: UInt = #line
) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        print("FAIL [\(file):\(line)]: \(message)")
    }
}

private func expectEqual<T: Equatable>(
    _ actual: T, _ expected: T, _ message: String,
    file: StaticString = #file, line: UInt = #line
) {
    expect(actual == expected, "\(message) -- expected \(expected), got \(actual)", file: file, line: line)
}

private func unit(
    id: String, owner: Int = 0, hp: Int = 60, maxHP: Int = 60, kind: String = "unit-footman"
) -> TabletopGameplayUnit {
    TabletopGameplayUnit(
        id: id, owner: owner, hp: hp, maxHP: maxHP,
        facingRadians: 0, tileX: 0, tileZ: 0, kind: kind)
}

private func snapshot(
    units: [TabletopGameplayUnit], selected: String?
) -> TabletopGameplaySnapshot {
    TabletopGameplaySnapshot(
        version: TabletopGameplaySnapshot.currentVersion,
        mapSize: TabletopMapSize(width: 8, height: 8),
        terrain: [], fogMask: [], units: units,
        selection: TabletopGameplaySelection(selectedUnitID: selected))
}

// MARK: - No selection: everything disabled, nothing forwards a command

func testNoSelectionDisablesEveryAction() {
    let ctx = TabletopActionPanel.context(for: snapshot(units: [unit(id: "1")], selected: nil))
    expect(!ctx.hasSelection, "no selected id => no selection")
    expectEqual(ctx.title, "No unit selected", "no-selection title")
    for item in ctx.items {
        expect(!item.isEnabled, "\(item.action) must be disabled with no selection")
    }
    expect(ctx.item(.deselect)?.command == nil, "deselect forwards no command when disabled")
    expect(ctx.item(.stop)?.command == nil, "stop forwards no command when disabled")
}

// MARK: - Live selection: deselect + stop forward the exact production commands

func testSelectionEnablesAndForwardsCommands() {
    let ctx = TabletopActionPanel.context(
        for: snapshot(units: [unit(id: "7", owner: 1, hp: 45, maxHP: 60, kind: "unit-grunt")],
                      selected: "7"))
    expect(ctx.hasSelection, "a live selected unit is a selection")
    expectEqual(ctx.title, "Grunt", "title is the readable unit name")
    expectEqual(ctx.subtitle, "HP 45/60 · Player 2", "subtitle shows HP and 1-based player")

    let deselect = ctx.item(.deselect)
    expect(deselect?.isEnabled == true, "deselect enabled with a selection")
    expectEqual(deselect?.command, .deselectAll, "deselect forwards deselectAll")

    let stop = ctx.item(.stop)
    expect(stop?.isEnabled == true, "stop enabled with a selection")
    expectEqual(stop?.command, .stopUnit(id: "7"), "stop forwards stopUnit for the selected id")
}

// MARK: - Move is an affordance, not a command button

func testMoveAffordanceCarriesNoCommand() {
    let ctx = TabletopActionPanel.context(for: snapshot(units: [unit(id: "3")], selected: "3"))
    let move = ctx.item(.move)
    expect(move != nil, "move item is present")
    expect(move?.isEnabled == true, "move is enabled while a unit is selected")
    expect(move?.command == nil, "move forwards no direct command (tap-to-move)")
}

// MARK: - A dead selected unit never enables actions

func testDeadSelectionIsNotActionable() {
    let ctx = TabletopActionPanel.context(
        for: snapshot(units: [unit(id: "9", hp: 0)], selected: "9"))
    expect(!ctx.hasSelection, "a dead selected unit is not an active selection")
    for item in ctx.items {
        expect(!item.isEnabled, "\(item.action) disabled for a dead selection")
    }
}

// MARK: - Item ordering is stable and complete

func testItemsAreStableAndComplete() {
    let ctx = TabletopActionPanel.context(for: snapshot(units: [unit(id: "1")], selected: "1"))
    expectEqual(ctx.items.map { $0.action }, [.deselect, .move, .stop],
                "panel items are ordered deselect, move, stop")
}

// MARK: - Readable-name mapping

func testDisplayNameMapping() {
    expectEqual(TabletopActionPanel.displayName(forKind: "unit-footman"), "Footman", "strips unit- and capitalises")
    expectEqual(TabletopActionPanel.displayName(forKind: "unit-great-hall"), "Great Hall", "multi-word ident")
    expectEqual(TabletopActionPanel.displayName(forKind: ""), "Unit", "empty ident falls back to Unit")
    expectEqual(TabletopActionPanel.displayName(forKind: "unit-ogre"), "Ogre", "single word")
}

@main
struct TabletopActionPanelTestRunner {
    static func main() {
        testNoSelectionDisablesEveryAction()
        testSelectionEnablesAndForwardsCommands()
        testMoveAffordanceCarriesNoCommand()
        testDeadSelectionIsNotActionable()
        testItemsAreStableAndComplete()
        testDisplayNameMapping()

        if failureCount > 0 {
            print("FAILED: \(failureCount)/\(checkCount) checks failed")
            exit(1)
        }
        print("PASSED: \(checkCount)/\(checkCount) checks")
    }
}
