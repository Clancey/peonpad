// TabletopBoardReconciler.swift
//
// Pure-logic snapshot diffing for incremental RealityKit board reconciliation.
//
// Nothing in this file imports SwiftUI, RealityKit, or UIKit. The diff
// computation here is framework-independent and unit-testable on the host Mac.
// The application of each diff category (adding/removing/updating RealityKit
// entities) lives in TabletopBoardView, which does import RealityKit.
import Foundation

// MARK: - Unit diff

/// The set of fields that changed for one unit between two snapshots.
/// Only units with at least one changed field appear in the `updatedUnits`
/// list of a `TabletopSnapshotDiff`.
public struct TabletopUnitDiff: Equatable {
    /// The stable unit identifier.
    public let id: String
    /// `tileX` or `tileZ` changed — the board entity needs repositioning.
    public let positionChanged: Bool
    /// `facingRadians` changed — the directional frame needs refresh.
    public let facingChanged: Bool
    /// `hp` or `maxHP` changed — alive/dead visual needs updating.
    public let hpChanged: Bool
    /// `owner` changed — the unit's team-color tint needs updating.
    public let ownerChanged: Bool
    /// `spriteFrame` or `spriteMirror` changed — the unit's sprite frame needs
    /// re-cropping even when its logical facing/position did not change (e.g. a
    /// walk/attack animation advancing in place).
    public let frameChanged: Bool
    /// The unit's presence in the selection changed — the highlight needs
    /// to be toggled.
    public let selectionChanged: Bool
}

// MARK: - Snapshot diff

/// The minimal set of changes between two consecutive gameplay snapshots.
/// Entities absent from all lists are unchanged and need no reconciliation.
public struct TabletopSnapshotDiff: Equatable {
    /// Units that appear in `to` but not in `from` — new entities to create.
    public let addedUnits: [TabletopGameplayUnit]
    /// Units that exist in both snapshots but whose state changed — entities
    /// to update in-place without recreating.
    public let updatedUnits: [TabletopUnitDiff]
    /// Unit IDs present in `from` but absent from `to` — entities to remove.
    public let removedUnitIDs: [String]
    /// Terrain tiles whose `kind` changed — tile material to refresh.
    public let changedTerrainTiles: [TabletopTerrainTile]
    /// Fog tiles whose `isRevealed` changed — fog overlay to refresh.
    public let changedFogTiles: [TabletopFogTile]

    /// True when the diff carries no changes at all.
    public var isEmpty: Bool {
        addedUnits.isEmpty &&
        updatedUnits.isEmpty &&
        removedUnitIDs.isEmpty &&
        changedTerrainTiles.isEmpty &&
        changedFogTiles.isEmpty
    }
}

// MARK: - Reconciler

/// Produces minimal `TabletopSnapshotDiff` values between consecutive
/// gameplay snapshots so the board can update incrementally without
/// rebuilding the RealityKit entity hierarchy from scratch.
public enum TabletopBoardReconciler {

    // MARK: Public

    /// Diffs `previous` against `next` and returns what changed.
    ///
    /// Pass `nil` for `previous` to treat every entity in `next` as newly
    /// added — the correct call for the very first snapshot that arrives
    /// after the board root has been placed in the scene.
    public static func diff(
        from previous: TabletopGameplaySnapshot?,
        to next: TabletopGameplaySnapshot
    ) -> TabletopSnapshotDiff {
        guard let previous else {
            // First snapshot: everything is "new".
            return TabletopSnapshotDiff(
                addedUnits: next.units,
                updatedUnits: [],
                removedUnitIDs: [],
                changedTerrainTiles: next.terrain,
                changedFogTiles: next.fogMask
            )
        }

        // -- Units --
        let previousByID = Dictionary(uniqueKeysWithValues: previous.units.map { ($0.id, $0) })
        let nextByID     = Dictionary(uniqueKeysWithValues: next.units.map     { ($0.id, $0) })

        let added   = next.units.filter    { previousByID[$0.id] == nil }
        let removed = previous.units.compactMap { nextByID[$0.id] == nil ? $0.id : nil }

        var updated: [TabletopUnitDiff] = []
        for unit in next.units {
            guard let old = previousByID[unit.id] else { continue }   // new units handled above
            let posChanged = old.tileX != unit.tileX || old.tileZ != unit.tileZ
            let facingChanged = old.facingRadians != unit.facingRadians
            let hpChanged = old.hp != unit.hp || old.maxHP != unit.maxHP
            let ownerChanged = old.owner != unit.owner
            let frameChanged = old.spriteFrame != unit.spriteFrame
                || old.spriteMirror != unit.spriteMirror
            let wasSelected = previous.selection.selectedUnitID == unit.id
            let isSelected  = next.selection.selectedUnitID == unit.id
            let selChanged  = wasSelected != isSelected

            if posChanged || facingChanged || hpChanged || ownerChanged
                || frameChanged || selChanged {
                updated.append(TabletopUnitDiff(
                    id: unit.id,
                    positionChanged: posChanged,
                    facingChanged: facingChanged,
                    hpChanged: hpChanged,
                    ownerChanged: ownerChanged,
                    frameChanged: frameChanged,
                    selectionChanged: selChanged
                ))
            }
        }

        // -- Terrain -- (changed when either the terrain kind or the tileset
        // graphic index differs, so real tile art refreshes too).
        let previousTerrain = Dictionary(
            uniqueKeysWithValues: previous.terrain.map {
                (tileKey($0.tileX, $0.tileZ), $0)
            }
        )
        let changedTerrain = next.terrain.filter { tile in
            guard let old = previousTerrain[tileKey(tile.tileX, tile.tileZ)] else { return true }
            return old.kind != tile.kind || old.graphicIndex != tile.graphicIndex
        }

        // -- Fog --
        let previousFog = Dictionary(
            uniqueKeysWithValues: previous.fogMask.map { (tileKey($0.tileX, $0.tileZ), $0.isRevealed) }
        )
        let changedFog = next.fogMask.filter { tile in
            previousFog[tileKey(tile.tileX, tile.tileZ)] != tile.isRevealed
        }

        return TabletopSnapshotDiff(
            addedUnits: added,
            updatedUnits: updated,
            removedUnitIDs: removed,
            changedTerrainTiles: changedTerrain,
            changedFogTiles: changedFog
        )
    }

    // MARK: Private helpers

    /// A dense, collision-free integer key for tile coordinates in the range
    /// [-9999, 9999], sufficient for any map size the engine will produce.
    private static func tileKey(_ x: Int, _ z: Int) -> Int {
        (x + 10_000) * 20_001 + (z + 10_000)
    }
}
