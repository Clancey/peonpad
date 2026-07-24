// tabletop_gameplay_state_test.swift
//
// Standalone pure-logic regression tests for the gameplay snapshot model and
// command reducer in TabletopGameplayState.swift. No dependency on RealityKit,
// SwiftUI, or UIKit; compiles and runs on the host Mac:
//
//   ./scripts/test-visionos-tabletop-gameplay.sh
//
// Deliberately does not use Swift's `assert`, which some optimized build
// configurations strip: failures are checked and reported explicitly.

import Foundation

private var failureCount = 0
private var checkCount = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        print("FAIL [\(file):\(line)]: \(message)")
    }
}

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    expect(actual == expected, "\(message) -- expected \(expected), got \(actual)", file: file, line: line)
}

// MARK: - Snapshot versioning and Codable round-trip

func testSnapshotCurrentVersion() {
    let snap = TabletopGameplaySnapshot.demo()
    expectEqual(snap.version, TabletopGameplaySnapshot.currentVersion,
                "demo snapshot carries the current schema version")
}

func testSnapshotCodableRoundTrip() {
    let original = TabletopGameplaySnapshot.demo()
    guard let encoded = try? JSONEncoder().encode(original) else {
        failureCount += 1; checkCount += 1
        print("FAIL: JSONEncoder failed on demo snapshot")
        return
    }
    guard let decoded = try? JSONDecoder().decode(TabletopGameplaySnapshot.self, from: encoded) else {
        failureCount += 1; checkCount += 1
        print("FAIL: JSONDecoder failed to round-trip demo snapshot")
        return
    }
    expectEqual(decoded, original, "snapshot survives a JSON encode/decode round-trip unchanged")
}

// MARK: - ABI v5 pathRoot backward compatibility

// Regression coverage: TabletopGameplaySnapshot.currentVersion is still 1,
// and TabletopTilesetInfo.pathRoot (ABI v5) is a new, non-optional stored
// property. A synthesized Decodable would require the "pathRoot" key to be
// present, so any snapshot serialized before this field existed (e.g. a
// persisted save, or simply an older running build's output) would fail to
// decode with keyNotFound — TabletopTilesetInfo has a custom init(from:)
// specifically to prevent this.

func testTilesetInfoDirectDecodeMissingPathRoot() {
    let json = """
    {"imagePath":"tilesets/summer/terrain/summer.png","pixelTileWidth":32,\
    "pixelTileHeight":32,"imageWidth":0,"imageHeight":0,"name":"Forest"}
    """.data(using: .utf8)!
    guard let decoded = try? JSONDecoder().decode(TabletopTilesetInfo.self, from: json) else {
        failureCount += 1; checkCount += 1
        print("FAIL: TabletopTilesetInfo failed to decode without a pathRoot key")
        return
    }
    expectEqual(decoded.pathRoot, .dataRoot, "missing pathRoot key defaults to .dataRoot")
    expectEqual(decoded.imagePath, "tilesets/summer/terrain/summer.png", "imagePath still decodes correctly")
    expectEqual(decoded.pixelTileWidth, 32, "pixelTileWidth still decodes correctly")
}

func testLegacySnapshotMissingTilesetPathRootDecodes() {
    var original = TabletopGameplaySnapshot.demo()
    original.assets = TabletopAssetCatalog(tileset: TabletopTilesetInfo(
        imagePath: "tilesets/summer/terrain/summer.png",
        pixelTileWidth: 32, pixelTileHeight: 32,
        imageWidth: 512, imageHeight: 768, name: "Forest",
        pathRoot: .cacheRoot))

    guard let encoded = try? JSONEncoder().encode(original),
          let jsonAny = try? JSONSerialization.jsonObject(with: encoded),
          var json = jsonAny as? [String: Any]
    else {
        failureCount += 1; checkCount += 1
        print("FAIL: could not encode/re-parse snapshot as a JSON object")
        return
    }

    // Simulate a legacy payload (persisted/produced before ABI v5 added
    // pathRoot) by stripping the key from the nested tileset object.
    guard var assets = json["assets"] as? [String: Any],
          var tileset = assets["tileset"] as? [String: Any]
    else {
        failureCount += 1; checkCount += 1
        print("FAIL: could not locate assets.tileset in the encoded JSON")
        return
    }
    expect(tileset["pathRoot"] != nil, "precondition: the freshly-encoded tileset carries pathRoot")
    tileset.removeValue(forKey: "pathRoot")
    assets["tileset"] = tileset
    json["assets"] = assets

    guard let strippedData = try? JSONSerialization.data(withJSONObject: json) else {
        failureCount += 1; checkCount += 1
        print("FAIL: could not re-serialize the stripped JSON")
        return
    }

    guard let decoded = try? JSONDecoder().decode(TabletopGameplaySnapshot.self, from: strippedData) else {
        failureCount += 1; checkCount += 1
        print("FAIL: a legacy snapshot missing tileset.pathRoot failed to decode (keyNotFound regression)")
        return
    }
    expectEqual(decoded.version, TabletopGameplaySnapshot.currentVersion,
                "a legacy snapshot still reports the current schema version — no format migration needed")
    expectEqual(decoded.assets?.tileset?.pathRoot, .dataRoot,
                "a missing pathRoot decodes as .dataRoot, matching pre-v5 (data-root-only) semantics")
    expectEqual(decoded.assets?.tileset?.imagePath, "tilesets/summer/terrain/summer.png",
                "other tileset fields still decode correctly alongside the defaulted pathRoot")
}

// MARK: - Demo snapshot structure

func testDemoSnapshotUnitCount() {
    let snap = TabletopGameplaySnapshot.demo()
    expectEqual(snap.units.count, 8, "demo snapshot has exactly eight test units (one per canonical direction)")
}

func testDemoUnitsAllAlive() {
    let snap = TabletopGameplaySnapshot.demo()
    for unit in snap.units {
        expect(unit.hp > 0, "demo unit \(unit.id) starts with hp > 0")
        expect(unit.maxHP >= unit.hp, "demo unit \(unit.id) maxHP >= hp")
        expect(unit.isAlive, "demo unit \(unit.id).isAlive matches hp > 0")
    }
}

func testDemoSnapshotTerrainAccessor() {
    let snap = TabletopGameplaySnapshot.demo()
    let half = snap.mapSize.width / 2
    var visitedCount = 0
    for z in -half...half {
        for x in -half...half {
            let kind = snap.terrain(atTileX: x, tileZ: z)
            expect(TabletopTerrainKind.allCases.contains(kind),
                   "terrain at (\(x), \(z)) is a known kind")
            visitedCount += 1
        }
    }
    expectEqual(visitedCount, snap.mapSize.width * snap.mapSize.height,
                "accessor was called for every tile in the map")
}

func testDemoSnapshotFogAccessor() {
    let snap = TabletopGameplaySnapshot.demo()
    // All demo tiles are revealed.
    let half = snap.mapSize.width / 2
    for z in -half...half {
        for x in -half...half {
            expect(snap.fog(atTileX: x, tileZ: z),
                   "all demo tiles are initially revealed (isRevealed == true)")
        }
    }
}

func testDemoSnapshotOffMapTerrain() {
    let snap = TabletopGameplaySnapshot.demo()
    // Off-map queries must return the fallback without trapping.
    expectEqual(snap.terrain(atTileX: 999, tileZ: 999), .grass,
                "out-of-bounds terrain query returns grass fallback")
    expect(!snap.fog(atTileX: 999, tileZ: 999),
           "out-of-bounds fog query returns false (unrevealed) fallback")
}

func testDemoSnapshotNoInitialSelection() {
    let snap = TabletopGameplaySnapshot.demo()
    expect(snap.selection.selectedUnitID == nil, "demo snapshot starts with no unit selected")
    expect(snap.validatedSelectedUnit == nil, "validatedSelectedUnit is nil when nothing is selected")
}

// MARK: - Command: selectUnit

func testSelectAliveUnit() {
    var snap = TabletopGameplaySnapshot.demo()
    let validation = TabletopGameplayCommandReducer.validate(snap, command: .selectUnit(id: "sentry.north"))
    expectEqual(validation, .valid, "selecting an alive unit validates as .valid")
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .selectUnit(id: "sentry.north"))
    expectEqual(snap.selection.selectedUnitID, "sentry.north",
                "selecting an alive unit sets the selection to that unit's ID")
}

func testSelectDeadUnitIsRejected() {
    var snap = TabletopGameplaySnapshot.demo()
    if let idx = snap.units.firstIndex(where: { $0.id == "sentry.north" }) {
        snap.units[idx].hp = 0
    }
    let validation = TabletopGameplayCommandReducer.validate(snap, command: .selectUnit(id: "sentry.north"))
    switch validation {
    case .rejectedDeadUnit(let id, let hp):
        expectEqual(id, "sentry.north", "dead-unit rejection carries the correct unit ID")
        expectEqual(hp, 0, "dead-unit rejection carries hp == 0")
    default:
        failureCount += 1; checkCount += 1
        print("FAIL: expected .rejectedDeadUnit, got \(validation)")
    }
    // reduce must also be a no-op for a dead unit
    let beforeReduce = snap
    let afterReduce = TabletopGameplayCommandReducer.reduce(snap, command: .selectUnit(id: "sentry.north"))
    expectEqual(afterReduce.selection.selectedUnitID, beforeReduce.selection.selectedUnitID,
                "selecting a dead unit does not change the selection state")
}

func testSelectUnknownUnitIsRejected() {
    let snap = TabletopGameplaySnapshot.demo()
    let validation = TabletopGameplayCommandReducer.validate(snap, command: .selectUnit(id: "ghost.unit"))
    switch validation {
    case .rejectedUnitNotFound(let id):
        expectEqual(id, "ghost.unit", "unit-not-found rejection carries the queried ID")
    default:
        failureCount += 1; checkCount += 1
        print("FAIL: expected .rejectedUnitNotFound, got \(validation)")
    }
}

// MARK: - Validated selection excludes dead units (defect regression)

func testValidatedSelectedUnitExcludesDeadUnit() {
    var snap = TabletopGameplaySnapshot.demo()
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .selectUnit(id: "sentry.north"))
    expect(snap.validatedSelectedUnit?.id == "sentry.north",
           "alive selected unit is returned by validatedSelectedUnit")

    // Kill the selected unit.
    if let idx = snap.units.firstIndex(where: { $0.id == "sentry.north" }) {
        snap.units[idx].hp = 0
    }
    expect(snap.selection.selectedUnitID == "sentry.north",
           "selection ID is still set after the unit is killed")
    expect(snap.validatedSelectedUnit == nil,
           "validatedSelectedUnit returns nil when the selected unit is dead (HP == 0)")
}

// MARK: - Command: deselectAll

func testDeselectAll() {
    var snap = TabletopGameplaySnapshot.demo()
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .selectUnit(id: "sentry.north"))
    expectEqual(snap.selection.selectedUnitID, "sentry.north", "unit selected before deselectAll")
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .deselectAll)
    expect(snap.selection.selectedUnitID == nil, "deselectAll clears the selection")
    expectEqual(
        TabletopGameplayCommandReducer.validate(snap, command: .deselectAll), .valid,
        "deselectAll is always valid"
    )
}

// MARK: - Command: moveUnit

func testMoveAliveUnit() {
    var snap = TabletopGameplaySnapshot.demo()
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .moveUnit(id: "sentry.north", toTileX: 1, toTileZ: 1))
    let moved = snap.units.first(where: { $0.id == "sentry.north" })!
    expectEqual(moved.tileX, 1, "moveUnit updates the unit's tileX in the snapshot")
    expectEqual(moved.tileZ, 1, "moveUnit updates the unit's tileZ in the snapshot")
    // Other units must not be affected.
    let others = snap.units.filter { $0.id != "sentry.north" }
    let demo = TabletopGameplaySnapshot.demo().units.filter { $0.id != "sentry.north" }
    expectEqual(others.count, demo.count, "other units are not removed by a move command")
    for (o, d) in zip(others, demo) {
        expectEqual(o.tileX, d.tileX, "other unit \(o.id) tileX unchanged after move")
        expectEqual(o.tileZ, d.tileZ, "other unit \(o.id) tileZ unchanged after move")
    }
}

func testMoveDeadUnitIsRejected() {
    var snap = TabletopGameplaySnapshot.demo()
    let originalTileX = snap.units.first(where: { $0.id == "sentry.north" })!.tileX
    let originalTileZ = snap.units.first(where: { $0.id == "sentry.north" })!.tileZ
    if let idx = snap.units.firstIndex(where: { $0.id == "sentry.north" }) {
        snap.units[idx].hp = 0
    }
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .moveUnit(id: "sentry.north", toTileX: 3, toTileZ: 3))
    let unit = snap.units.first(where: { $0.id == "sentry.north" })!
    expectEqual(unit.tileX, originalTileX, "dead unit tileX not changed by move command")
    expectEqual(unit.tileZ, originalTileZ, "dead unit tileZ not changed by move command")
}

func testMoveUnknownUnitIsRejected() {
    let snap = TabletopGameplaySnapshot.demo()
    let validation = TabletopGameplayCommandReducer.validate(
        snap, command: .moveUnit(id: "ghost.unit", toTileX: 0, toTileZ: 0)
    )
    switch validation {
    case .rejectedUnitNotFound(let id):
        expectEqual(id, "ghost.unit", "move-unknown-unit rejection carries the queried ID")
    default:
        failureCount += 1; checkCount += 1
        print("FAIL: expected .rejectedUnitNotFound for move, got \(validation)")
    }
}

// MARK: - Command: stopUnit

func testStopAliveUnit() {
    let snap = TabletopGameplaySnapshot.demo()
    let validation = TabletopGameplayCommandReducer.validate(snap, command: .stopUnit(id: "sentry.north"))
    expectEqual(validation, .valid, "stopping an alive unit is valid")
    // In the pure state model, stop is a no-op beyond validation.
    let newSnap = TabletopGameplayCommandReducer.reduce(snap, command: .stopUnit(id: "sentry.north"))
    expectEqual(newSnap, snap, "stop command on an alive unit does not mutate the snapshot")
}

func testStopDeadUnitIsRejected() {
    var snap = TabletopGameplaySnapshot.demo()
    if let idx = snap.units.firstIndex(where: { $0.id == "sentry.north" }) {
        snap.units[idx].hp = 0
    }
    let validation = TabletopGameplayCommandReducer.validate(snap, command: .stopUnit(id: "sentry.north"))
    switch validation {
    case .rejectedDeadUnit(let id, _):
        expectEqual(id, "sentry.north", "stop-dead-unit rejection carries the unit ID")
    default:
        failureCount += 1; checkCount += 1
        print("FAIL: expected .rejectedDeadUnit for stop, got \(validation)")
    }
}

func testStopUnknownUnitIsRejected() {
    let snap = TabletopGameplaySnapshot.demo()
    let validation = TabletopGameplayCommandReducer.validate(snap, command: .stopUnit(id: "ghost.unit"))
    switch validation {
    case .rejectedUnitNotFound(let id):
        expectEqual(id, "ghost.unit", "stop-unknown-unit rejection carries the queried ID")
    default:
        failureCount += 1; checkCount += 1
        print("FAIL: expected .rejectedUnitNotFound for stop, got \(validation)")
    }
}

// MARK: - Command reducer idempotence and ordering

func testReduceReturnsUnchangedSnapshotForInvalidCommand() {
    var snap = TabletopGameplaySnapshot.demo()
    if let idx = snap.units.firstIndex(where: { $0.id == "sentry.north" }) {
        snap.units[idx].hp = 0
    }
    let before = snap
    let after = TabletopGameplayCommandReducer.reduce(snap, command: .selectUnit(id: "sentry.north"))
    expectEqual(after, before, "an invalid command returns the snapshot unchanged (no partial mutation)")
}

func testSelectThenDeselectRestoresNoSelection() {
    var snap = TabletopGameplaySnapshot.demo()
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .selectUnit(id: "sentry.north"))
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .deselectAll)
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .selectUnit(id: "sentry.east"))
    expectEqual(snap.selection.selectedUnitID, "sentry.east",
                "select after deselectAll selects the new unit")
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .deselectAll)
    expect(snap.selection.selectedUnitID == nil,
           "deselectAll after a second select clears selection again")
}

func testMoveThenMoveAgainComposes() {
    var snap = TabletopGameplaySnapshot.demo()
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .moveUnit(id: "sentry.north", toTileX: 1, toTileZ: 0))
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .moveUnit(id: "sentry.north", toTileX: -1, toTileZ: -1))
    let unit = snap.units.first(where: { $0.id == "sentry.north" })!
    expectEqual(unit.tileX, -1, "second move command overwrites the first")
    expectEqual(unit.tileZ, -1, "second move command overwrites the first (Z)")
}

// MARK: - Authoritative action reducer

func makeActionSnapshot(
    enabled: Bool = true,
    targetKind: TabletopActionTargetKind = .map
) -> TabletopGameplaySnapshot {
    var snap = TabletopGameplaySnapshot.demo()
    snap.actions = [
        TabletopEngineAction(
            id: 0x123, slot: 4, panelLevel: 1, kind: .spellCast,
            isVisible: true, isEnabled: enabled, targetKind: targetKind,
            valueIdent: "spell-healing", text: "Heal"),
    ]
    return snap
}

func testExactActionActivationStartsTargeting() {
    var snap = makeActionSnapshot()
    expectEqual(TabletopGameplayCommandReducer.validate(
        snap, command: .activateAction(id: 0x123, slot: 4)), .valid,
        "matching visible enabled action is valid")
    snap = TabletopGameplayCommandReducer.reduce(
        snap, command: .activateAction(id: 0x123, slot: 4))
    expectEqual(snap.actionState.targetKind, .map,
                "targeting action exposes board target state")
    expectEqual(snap.actionState.targetActionKind, .spellCast,
                "pending target records action kind")
    expectEqual(snap.actionState.targetActionID, 0x123,
                "pending target records stable action identity")
    expectEqual(snap.actionState.targetSlot, 4,
                "pending target records exact engine slot")
}

func testActionActivationRejectsDisabledAndStaleDescriptors() {
    let disabled = makeActionSnapshot(enabled: false)
    expectEqual(TabletopGameplayCommandReducer.validate(
        disabled, command: .activateAction(id: 0x123, slot: 4)),
        .rejectedActionDisabled(id: 0x123, slot: 4),
        "disabled engine action cannot activate")
    expectEqual(TabletopGameplayCommandReducer.reduce(
        disabled, command: .activateAction(id: 0x123, slot: 4)), disabled,
        "disabled activation leaves state unchanged")

    let current = makeActionSnapshot()
    expectEqual(TabletopGameplayCommandReducer.validate(
        current, command: .activateAction(id: 0x999, slot: 4)),
        .rejectedActionNotFound(id: 0x999, slot: 4),
        "stale action identity is rejected")
    expectEqual(TabletopGameplayCommandReducer.validate(
        current, command: .activateAction(id: 0x123, slot: 5)),
        .rejectedActionNotFound(id: 0x123, slot: 5),
        "stale action slot is rejected")
}

func testTargetSubmitAndCancellationTransitions() {
    var snap = TabletopGameplayCommandReducer.reduce(
        makeActionSnapshot(), command: .activateAction(id: 0x123, slot: 4))
    expectEqual(TabletopGameplayCommandReducer.validate(
        snap, command: .submitActionTarget(tileX: 2, tileZ: 3)), .valid,
        "in-bounds target is valid while targeting")
    expectEqual(TabletopGameplayCommandReducer.validate(
        snap, command: .submitActionTarget(tileX: 99, tileZ: 3)),
        .rejectedTargetOutOfBounds(tileX: 99, tileZ: 3),
        "out-of-bounds target is rejected")

    snap = TabletopGameplayCommandReducer.reduce(
        snap, command: .submitActionTarget(tileX: 2, tileZ: 3))
    expect(!snap.actionState.isAwaitingBoardTarget,
           "accepted target clears pending target state")

    expectEqual(TabletopGameplayCommandReducer.validate(
        snap, command: .submitActionTarget(tileX: 2, tileZ: 3)),
        .rejectedNoPendingTarget,
        "follow-up target without pending action is rejected")

    snap = TabletopGameplayCommandReducer.reduce(
        makeActionSnapshot(), command: .activateAction(id: 0x123, slot: 4))
    snap.actionState.panelLevel = 2
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .cancelAction)
    expect(!snap.actionState.isAwaitingBoardTarget,
           "cancel clears target/build placement")
    expectEqual(snap.actionState.panelLevel, 0, "cancel/back returns to root panel")
}

func testPauseResumeTransitions() {
    var snap = TabletopGameplayCommandReducer.reduce(
        makeActionSnapshot(), command: .activateAction(id: 0x123, slot: 4))
    snap.actionState.panelLevel = 2
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .pause)
    expect(snap.actionState.isPaused, "pause sets explicit engine state")
    expect(!snap.actionState.isAwaitingBoardTarget,
           "pause clears incompatible targeting state")
    expectEqual(snap.actionState.panelLevel, 0,
                "pause returns the pure model to the root panel")
    snap = TabletopGameplayCommandReducer.reduce(snap, command: .resume)
    expect(!snap.actionState.isPaused, "resume clears explicit engine state")
}

func testSubmenuActivationTransitionsPanelLevel() {
    var snap = makeActionSnapshot(targetKind: .none)
    snap.actions = [
        TabletopEngineAction(
            id: 0x456, slot: 6, kind: .submenu, value: 3, text: "Build"),
    ]
    snap = TabletopGameplayCommandReducer.reduce(
        snap, command: .activateAction(id: 0x456, slot: 6))
    expectEqual(snap.actionState.panelLevel, 3,
                "submenu activation mirrors the engine panel transition")
}

func testSelectionChangeCancelsPendingTarget() {
    var snap = TabletopGameplayCommandReducer.reduce(
        makeActionSnapshot(), command: .activateAction(id: 0x123, slot: 4))
    expect(snap.actionState.isAwaitingBoardTarget, "fixture begins in target mode")
    snap = TabletopGameplayCommandReducer.reduce(
        snap, command: .selectUnit(id: "sentry.east"))
    expectEqual(snap.selection.selectedUnitID, "sentry.east",
                "selection change still applies")
    expect(!snap.actionState.isAwaitingBoardTarget,
           "selection change explicitly cancels stale target state")
}

@main
struct TabletopGameplayStateTestRunner {
    static func main() {
        testSnapshotCurrentVersion()
        testSnapshotCodableRoundTrip()
        testTilesetInfoDirectDecodeMissingPathRoot()
        testLegacySnapshotMissingTilesetPathRootDecodes()
        testDemoSnapshotUnitCount()
        testDemoUnitsAllAlive()
        testDemoSnapshotTerrainAccessor()
        testDemoSnapshotFogAccessor()
        testDemoSnapshotOffMapTerrain()
        testDemoSnapshotNoInitialSelection()
        testSelectAliveUnit()
        testSelectDeadUnitIsRejected()
        testSelectUnknownUnitIsRejected()
        testValidatedSelectedUnitExcludesDeadUnit()
        testDeselectAll()
        testMoveAliveUnit()
        testMoveDeadUnitIsRejected()
        testMoveUnknownUnitIsRejected()
        testStopAliveUnit()
        testStopDeadUnitIsRejected()
        testStopUnknownUnitIsRejected()
        testReduceReturnsUnchangedSnapshotForInvalidCommand()
        testSelectThenDeselectRestoresNoSelection()
        testMoveThenMoveAgainComposes()
        testExactActionActivationStartsTargeting()
        testActionActivationRejectsDisabledAndStaleDescriptors()
        testTargetSubmitAndCancellationTransitions()
        testPauseResumeTransitions()
        testSubmenuActivationTransitionsPanelLevel()
        testSelectionChangeCancelsPendingTarget()

        if failureCount > 0 {
            print("FAILED: \(failureCount)/\(checkCount) checks failed")
            exit(1)
        }
        print("PASSED: \(checkCount)/\(checkCount) checks")
    }
}
