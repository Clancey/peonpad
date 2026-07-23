// tabletop_live_state_test.swift
//
// Standalone pure-logic tests for the live-state consumer seam:
//   TabletopGameplaySource / TabletopCommandSink (DemoTabletopSession,
//   LiveTabletopSession), TabletopBoardReconciler, and AnyTabletopSession.
//
// No dependency on RealityKit, SwiftUI, or UIKit. Compiles and runs on the
// host Mac:
//
//   ./scripts/test-visionos-tabletop-live-state.sh
//
// The entry point is async to support awaiting AsyncStream values from
// DemoTabletopSession and LiveTabletopSession without blocking the main thread.

import Foundation

// MARK: - Minimal test harness

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
    expect(actual == expected,
           "\(message) -- expected \(expected), got \(actual)",
           file: file, line: line)
}

// MARK: - DemoTabletopSession: initial snapshot publication

func testDemoSessionPublishesInitialSnapshot() async {
    let session = DemoTabletopSession()
    var iter = session.snapshots.makeAsyncIterator()
    let first = await iter.next()
    expect(first != nil, "demo session publishes at least one snapshot immediately")
    expectEqual(first?.units.count, 8,
                "initial demo snapshot carries all eight test units")
    expectEqual(first?.selection.selectedUnitID, nil,
                "initial demo snapshot has no selection")
}

// MARK: - DemoTabletopSession: snapshot generation bumps on command

func testDemoSessionSnapshotChangesOnCommand() async {
    let session = DemoTabletopSession()
    var iter = session.snapshots.makeAsyncIterator()
    let initial = await iter.next()

    // Send a command that changes state.
    session.send(.selectUnit(id: "sentry.north"))

    let updated = await iter.next()
    expect(updated != nil, "session publishes a snapshot after a state-changing command")
    expect(updated != initial, "snapshot after command differs from initial snapshot")
    expectEqual(updated?.selection.selectedUnitID, "sentry.north",
                "updated snapshot reflects the selectUnit command")
}

// MARK: - DemoTabletopSession: no-op command does not publish

func testDemoSessionNoopCommandDoesNotPublish() async {
    let session = DemoTabletopSession()
    var iter = session.snapshots.makeAsyncIterator()
    _ = await iter.next()  // consume initial

    // Move a non-existent unit — invalid command, snapshot unchanged.
    session.send(.moveUnit(id: "ghost.unit", toTileX: 0, toTileZ: 0))

    // The next value must NOT be immediately available (no redundant publish).
    // We race a short timeout task against the iterator to detect spurious emission.
    let received = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = await iter.next()
            return true  // value received
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
            return false  // timed out — good
        }
        let result = await group.next()!
        group.cancelAll()
        return result
    }
    expect(!received, "invalid command must not produce a new snapshot")
}

// MARK: - DemoTabletopSession: multiple commands produce distinct snapshots

func testDemoSessionMultipleCommandsProduceDistinctSnapshots() async {
    let session = DemoTabletopSession()
    var iter = session.snapshots.makeAsyncIterator()
    _ = await iter.next()  // consume initial

    session.send(.selectUnit(id: "sentry.north"))
    let snap1 = await iter.next()

    session.send(.moveUnit(id: "sentry.north", toTileX: 1, toTileZ: 1))
    let snap2 = await iter.next()

    session.send(.deselectAll)
    let snap3 = await iter.next()

    expect(snap1 != nil && snap2 != nil && snap3 != nil,
           "each state-changing command produces a snapshot")
    expectEqual(snap1?.selection.selectedUnitID, "sentry.north",
                "snap1 reflects selectUnit")
    let movedUnit = snap2?.units.first(where: { $0.id == "sentry.north" })
    expectEqual(movedUnit?.tileX, 1, "snap2 reflects moveUnit tileX")
    expectEqual(movedUnit?.tileZ, 1, "snap2 reflects moveUnit tileZ")
    expect(snap3?.selection.selectedUnitID == nil, "snap3 reflects deselectAll")
}

// MARK: - DemoTabletopSession: command forwarding (stop)

func testDemoSessionStopCommandIsForwarded() async {
    let session = DemoTabletopSession()
    var iter = session.snapshots.makeAsyncIterator()
    let initial = await iter.next()!

    // stop on an alive unit is valid but leaves the snapshot unchanged.
    session.send(.stopUnit(id: "sentry.north"))

    // A stop command is a no-op in the pure state model — snapshot unchanged
    // means no new publish.
    let received = await withTaskGroup(of: Bool.self) { group in
        group.addTask { _ = await iter.next(); return true }
        group.addTask { try? await Task.sleep(nanoseconds: 50_000_000); return false }
        let r = await group.next()!
        group.cancelAll()
        return r
    }
    expect(!received, "stop command on alive unit does not produce a new snapshot")
    _ = initial  // suppress unused warning
}

// MARK: - LiveTabletopSession: missing transport produces empty stream

func testLiveSessionMissingTransportProducesEmptyStream() async {
    let session = LiveTabletopSession(transport: nil)
    var iter = session.snapshots.makeAsyncIterator()
    let value = await iter.next()
    expect(value == nil,
           "LiveTabletopSession with nil transport finishes immediately (empty stream)")
}

// MARK: - LiveTabletopSession: missing transport drops commands (no crash)

func testLiveSessionMissingTransportDropsCommands() {
    let session = LiveTabletopSession(transport: nil)
    // Must not crash or trap. Side-effect: prints a diagnostic log line.
    session.send(.deselectAll)
    session.send(.selectUnit(id: "sentry.north"))
    expect(true, "LiveTabletopSession drops commands silently when no transport is bound")
}

// MARK: - AnyTabletopSession: wraps source + sink

func testAnyTabletopSessionWrapsSourceAndSink() async {
    let demo = DemoTabletopSession()
    let any = AnyTabletopSession(demo)
    var iter = any.snapshots.makeAsyncIterator()
    let initial = await iter.next()
    expect(initial != nil, "AnyTabletopSession proxies snapshots from underlying session")

    any.send(.selectUnit(id: "sentry.east"))
    let updated = await iter.next()
    expectEqual(updated?.selection.selectedUnitID, "sentry.east",
                "AnyTabletopSession proxies commands to underlying session")
}

// MARK: - TabletopBoardReconciler: nil-previous is a full add

func testReconcilerNilPreviousAddsAllUnits() {
    let snap = TabletopGameplaySnapshot.demo()
    let diff = TabletopBoardReconciler.diff(from: nil, to: snap)
    expectEqual(diff.addedUnits.count, snap.units.count,
                "nil previous treats all units as newly added")
    expect(diff.updatedUnits.isEmpty, "nil previous has no updates")
    expect(diff.removedUnitIDs.isEmpty, "nil previous has no removals")
    expectEqual(diff.changedTerrainTiles.count, snap.terrain.count,
                "nil previous treats all terrain as new")
    expectEqual(diff.changedFogTiles.count, snap.fogMask.count,
                "nil previous treats all fog tiles as new")
}

// MARK: - TabletopBoardReconciler: identical snapshots produce empty diff

func testReconcilerIdenticalSnapshotsIsEmpty() {
    let snap = TabletopGameplaySnapshot.demo()
    let diff = TabletopBoardReconciler.diff(from: snap, to: snap)
    expect(diff.isEmpty, "identical snapshots produce an empty diff")
}

// MARK: - TabletopBoardReconciler: position change detected

func testReconcilerDetectsPositionChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    after.units[0].tileX = after.units[0].tileX + 1

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.updatedUnits.contains(where: { $0.id == after.units[0].id && $0.positionChanged }),
           "position change is detected in the diff")
    expect(!diff.updatedUnits.contains(where: { $0.id == after.units[0].id && $0.hpChanged }),
           "hp is NOT flagged as changed when only position changed")
}

// MARK: - TabletopBoardReconciler: HP change detected (alive → dead)

func testReconcilerDetectsHPChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    after.units[0].hp = 0

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.updatedUnits.contains(where: { $0.id == after.units[0].id && $0.hpChanged }),
           "HP change (alive → dead) is detected in the diff")
    expect(!diff.updatedUnits.contains(where: { $0.id == after.units[0].id && $0.positionChanged }),
           "position is NOT flagged as changed when only HP changed")
}

// MARK: - TabletopBoardReconciler: ownership change detected

func testReconcilerDetectsOwnerChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    let idx = after.units.firstIndex(where: { $0.owner == 0 })!
    after.units[idx].owner = 1

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.updatedUnits.contains(where: { $0.id == after.units[idx].id && $0.ownerChanged }),
           "owner change is detected in the diff")
}

// MARK: - TabletopBoardReconciler: animation frame + terrain graphic-index

func testReconcilerDetectsAnimationFrameChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    // Advance the sprite frame / mirror in place (no facing/position change).
    after.units[0].spriteFrame = (before.units[0].spriteFrame ?? 0) + 4
    after.units[0].spriteMirror = !(before.units[0].spriteMirror ?? false)

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.updatedUnits.contains(where: { $0.id == after.units[0].id && $0.frameChanged }),
           "sprite frame/mirror change is detected in the diff")
    expect(!diff.updatedUnits.contains(where: { $0.id == after.units[0].id && $0.positionChanged }),
           "position is NOT flagged when only the sprite frame changed")
}

func testReconcilerDetectsTerrainGraphicIndexChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    // Same terrain kind, different tileset graphic index → still a change.
    let g = after.terrain[0].graphicIndex ?? 0
    after.terrain[0].graphicIndex = g + 1

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.changedTerrainTiles.contains(where: {
        $0.tileX == after.terrain[0].tileX && $0.tileZ == after.terrain[0].tileZ
    }), "terrain graphic-index change is detected even when kind is unchanged")
}

func testReconcilerDetectsTerrainTileIndexChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    after.terrain[0].tileIndex = 0x100

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.changedTerrainTiles.contains(where: {
        $0.tileX == after.terrain[0].tileX && $0.tileZ == after.terrain[0].tileZ
    }), "terrain tile-index change refreshes solid-vs-transition relief")
}

// MARK: - TabletopBoardReconciler: selection change detected

func testReconcilerDetectsSelectionChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    after.selection = TabletopGameplaySelection(selectedUnitID: before.units[0].id)

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.updatedUnits.contains(where: { $0.id == before.units[0].id && $0.selectionChanged }),
           "selection change is detected in the diff for the newly selected unit")
}

// MARK: - TabletopBoardReconciler: deselection detected

func testReconcilerDetectsDeselection() {
    var before = TabletopGameplaySnapshot.demo()
    before.selection = TabletopGameplaySelection(selectedUnitID: before.units[0].id)
    var after = before
    after.selection = TabletopGameplaySelection()

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.updatedUnits.contains(where: { $0.id == before.units[0].id && $0.selectionChanged }),
           "deselection is detected in the diff for the previously selected unit")
}

// MARK: - TabletopBoardReconciler: unit removal detected

func testReconcilerDetectsUnitRemoval() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    let removedID = after.units.removeLast().id

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.removedUnitIDs.contains(removedID),
           "removed unit ID appears in removedUnitIDs")
    expect(!diff.addedUnits.contains(where: { $0.id == removedID }),
           "removed unit does not also appear in addedUnits")
}

// MARK: - TabletopBoardReconciler: unit addition detected

func testReconcilerDetectsUnitAddition() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    let newUnit = TabletopGameplayUnit(
        id: "new.unit.1", owner: 0, hp: 10, maxHP: 10,
        facingRadians: 0, tileX: 0, tileZ: 0
    )
    after.units.append(newUnit)

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.addedUnits.contains(where: { $0.id == "new.unit.1" }),
           "newly added unit appears in addedUnits")
    expect(!diff.removedUnitIDs.contains("new.unit.1"),
           "newly added unit does not appear in removedUnitIDs")
}

// MARK: - TabletopBoardReconciler: tileset identity change detected
//
// Regression coverage for the "stale atlas after tileset transition" bug:
// the engine's tileset descriptor can transition raw->generated (a delayed
// export retry succeeding after an initial failure) or generated v1->v2 (a
// same-process tileset reload — see PeonPadTabletopBridge.cpp's
// ExportExpandedTilesetPNG / TabletopTilesetExportCache) while every terrain
// tile's kind/graphicIndex stays exactly the same. `changedTerrainTiles`
// alone must not be the only signal driving atlas invalidation.

func testReconcilerDetectsTilesetPathChangeWithUnchangedTerrain() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    // Terrain is byte-for-byte identical...
    precondition(after.terrain == before.terrain, "precondition: terrain unchanged")

    // ...but the tileset transitioned from the raw asset to the engine's
    // generated-cache export (a delayed retry succeeding).
    after.assets = TabletopAssetCatalog(tileset: TabletopTilesetInfo(
        imagePath: "tilesets/summer/terrain/summer.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest", pathRoot: .dataRoot))
    let diff1 = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff1.changedTerrainTiles.isEmpty, "precondition: no terrain tile value changed")
    expect(diff1.tilesetChanged, "raw tileset appearing (nil -> Set) is flagged as a tileset change")
    expect(!diff1.isEmpty, "a tileset-only change must not be reported as an empty diff")

    var afterGenerated = after
    afterGenerated.assets = TabletopAssetCatalog(tileset: TabletopTilesetInfo(
        imagePath: "tabletop-generated/forest-v1-aaaa.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest", pathRoot: .cacheRoot))
    let diff2 = TabletopBoardReconciler.diff(from: after, to: afterGenerated)
    expect(diff2.changedTerrainTiles.isEmpty, "precondition: no terrain tile value changed")
    expect(diff2.tilesetChanged, "raw -> generated-cache transition is flagged as a tileset change")
}

func testReconcilerDetectsTilesetVersionChangeWithUnchangedTerrain() {
    let before = TabletopGameplaySnapshot.demo()
    var v1 = before
    v1.assets = TabletopAssetCatalog(tileset: TabletopTilesetInfo(
        imagePath: "tabletop-generated/forest-v1-aaaa.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest", pathRoot: .cacheRoot))
    var v2 = v1
    // Same tileset *name*, same terrain, but a new generated version (e.g. a
    // same-process reload regenerated a taller expanded surface) — the path
    // (and therefore the exported image content) differs.
    v2.assets = TabletopAssetCatalog(tileset: TabletopTilesetInfo(
        imagePath: "tabletop-generated/forest-v2-bbbb.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest", pathRoot: .cacheRoot))
    precondition(v1.terrain == v2.terrain, "precondition: terrain unchanged")

    let diff = TabletopBoardReconciler.diff(from: v1, to: v2)
    expect(diff.changedTerrainTiles.isEmpty, "precondition: no terrain tile value changed")
    expect(diff.tilesetChanged, "generated v1 -> v2 transition is flagged as a tileset change")
    expect(!diff.isEmpty, "a v1->v2-only change must not be reported as an empty diff")
}

func testReconcilerNoTilesetChangeWhenIdentical() {
    var before = TabletopGameplaySnapshot.demo()
    var after = before
    after.assets = TabletopAssetCatalog(tileset: TabletopTilesetInfo(
        imagePath: "tilesets/summer/terrain/summer.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest", pathRoot: .dataRoot))
    before.assets = after.assets

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(!diff.tilesetChanged, "identical tileset descriptors are not flagged as changed")
    expect(diff.isEmpty, "no changes anywhere => empty diff")
}

// MARK: - TabletopBoardReconciler: terrain change detected

func testReconcilerDetectsTerrainChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    let idx = after.terrain.firstIndex(where: { $0.kind == .grass })!
    after.terrain[idx].kind = .water

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    let changed = diff.changedTerrainTiles.first(where: {
        $0.tileX == after.terrain[idx].tileX && $0.tileZ == after.terrain[idx].tileZ
    })
    expect(changed != nil, "terrain kind change is detected in the diff")
    expectEqual(changed?.kind, .water, "changed terrain tile carries the new kind")
}

// MARK: - TabletopBoardReconciler: fog change detected

func testReconcilerDetectsFogChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    let idx = after.fogMask.firstIndex(where: { $0.isRevealed })!
    after.fogMask[idx].isRevealed = false

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    let changed = diff.changedFogTiles.first(where: {
        $0.tileX == after.fogMask[idx].tileX && $0.tileZ == after.fogMask[idx].tileZ
    })
    expect(changed != nil, "fog revelation change is detected in the diff")
    expect(!changed!.isRevealed, "changed fog tile carries isRevealed = false")
}

// MARK: - TabletopBoardReconciler: three-state fog transition detected

func testReconcilerDetectsExploredToVisibleTransition() {
    // A visible→explored transition (both count as "revealed") must still be
    // detected, because the diff compares the full three-state visibility. This
    // is the movement-triggered transition: a tile a unit walked away from goes
    // from clear to dim without ever passing through unexplored.
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    guard let idx = after.fogMask.firstIndex(where: { $0.visibility == .visible }) else {
        expect(false, "demo snapshot should have a visible tile"); return
    }
    after.fogMask[idx].visibility = .explored

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    let changed = diff.changedFogTiles.first(where: {
        $0.tileX == after.fogMask[idx].tileX && $0.tileZ == after.fogMask[idx].tileZ
    })
    expect(changed != nil, "visible→explored transition is detected even though both are 'revealed'")
    expectEqual(changed?.visibility, .explored, "changed tile carries the explored (dim) state")
    expect(changed?.isRevealed == true, "explored tile is still revealed")
}

// MARK: - TabletopBoardReconciler: facing change detected

func testReconcilerDetectsFacingChange() {
    let before = TabletopGameplaySnapshot.demo()
    var after = before
    after.units[0].facingRadians = WarcraftFacing.south.radians

    let diff = TabletopBoardReconciler.diff(from: before, to: after)
    expect(diff.updatedUnits.contains(where: { $0.id == after.units[0].id && $0.facingChanged }),
           "facing change is detected in the diff")
}

// MARK: - Lifecycle: task cancellation stops iteration

func testTaskCancellationStopsIteration() async {
    let session = DemoTabletopSession()
    var iteratedCount = 0

    let task = Task {
        for await _ in session.snapshots {
            iteratedCount += 1
            // Yield so the task cancellation can take effect.
            await Task.yield()
        }
    }

    // Let the task consume the initial snapshot.
    try? await Task.sleep(nanoseconds: 20_000_000)
    task.cancel()
    try? await Task.sleep(nanoseconds: 20_000_000)

    // After cancellation, new commands must not reach the cancelled iterator.
    let countBeforeCommand = iteratedCount
    session.send(.selectUnit(id: "sentry.north"))
    try? await Task.sleep(nanoseconds: 20_000_000)

    expect(iteratedCount == countBeforeCommand || iteratedCount == countBeforeCommand + 1,
           "after task cancellation no further snapshots are delivered to that task")
}

// MARK: - Concurrent sends are safe

func testConcurrentSendsAreSafe() async {
    let session = DemoTabletopSession()
    var iter = session.snapshots.makeAsyncIterator()
    _ = await iter.next()  // consume initial

    // Fire 10 commands concurrently to exercise the lock.
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<5 {
            group.addTask { session.send(.selectUnit(id: "sentry.north")) }
            group.addTask { session.send(.moveUnit(id: "sentry.east", toTileX: i, toTileZ: i)) }
        }
    }
    // As long as we didn't crash or deadlock the test passes.
    expect(true, "concurrent sends complete without deadlock or crash")
}

// MARK: - NullTabletopAssetResolver always returns nil

func testNullAssetResolverReturnsNil() {
    let resolver = NullTabletopAssetResolver()
    expect(resolver.terrainTexture(for: .grass) == nil,
           "NullTabletopAssetResolver returns nil for grass terrain texture")
    expect(resolver.terrainTexture(for: .water) == nil,
           "NullTabletopAssetResolver returns nil for water terrain texture")
    expect(resolver.unitSprite(unitKind: "footman", canonical: .north) == nil,
           "NullTabletopAssetResolver returns nil for unit sprite")
    expect(resolver.unitSprite(unitKind: "grunt", canonical: .east) == nil,
           "NullTabletopAssetResolver returns nil for enemy unit sprite")
}

// MARK: - Entry point

@main
struct TabletopLiveStateTestRunner {
    static func main() async {
        // DemoTabletopSession source/sink
        await testDemoSessionPublishesInitialSnapshot()
        await testDemoSessionSnapshotChangesOnCommand()
        await testDemoSessionNoopCommandDoesNotPublish()
        await testDemoSessionMultipleCommandsProduceDistinctSnapshots()
        await testDemoSessionStopCommandIsForwarded()

        // LiveTabletopSession missing transport
        await testLiveSessionMissingTransportProducesEmptyStream()
        testLiveSessionMissingTransportDropsCommands()

        // AnyTabletopSession
        await testAnyTabletopSessionWrapsSourceAndSink()

        // TabletopBoardReconciler
        testReconcilerNilPreviousAddsAllUnits()
        testReconcilerIdenticalSnapshotsIsEmpty()
        testReconcilerDetectsPositionChange()
        testReconcilerDetectsHPChange()
        testReconcilerDetectsOwnerChange()
        testReconcilerDetectsAnimationFrameChange()
        testReconcilerDetectsTerrainGraphicIndexChange()
        testReconcilerDetectsTerrainTileIndexChange()
        testReconcilerDetectsSelectionChange()
        testReconcilerDetectsDeselection()
        testReconcilerDetectsUnitRemoval()
        testReconcilerDetectsUnitAddition()
        testReconcilerDetectsTilesetPathChangeWithUnchangedTerrain()
        testReconcilerDetectsTilesetVersionChangeWithUnchangedTerrain()
        testReconcilerNoTilesetChangeWhenIdentical()
        testReconcilerDetectsTerrainChange()
        testReconcilerDetectsFogChange()
        testReconcilerDetectsExploredToVisibleTransition()
        testReconcilerDetectsFacingChange()

        // Lifecycle
        await testTaskCancellationStopsIteration()
        await testConcurrentSendsAreSafe()

        // Asset resolver seam
        testNullAssetResolverReturnsNil()

        if failureCount > 0 {
            print("FAILED: \(failureCount)/\(checkCount) checks failed")
            exit(1)
        }
        print("PASSED: \(checkCount)/\(checkCount) checks")
    }
}
