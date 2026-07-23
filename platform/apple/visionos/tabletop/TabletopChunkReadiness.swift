// TabletopChunkReadiness.swift
//
// Pure, framework-free chunk-key and streaming-readiness tracking for the
// visionOS tabletop board. No RealityKit/UIKit dependency, so the exact
// state machine TabletopChunkBoard uses to decide "is this chunk showing
// current real art" is unit-testable on the host Mac without a Simulator.
//
//   ./scripts/test-visionos-tabletop-chunks.sh
import Foundation

/// Identifies one terrain chunk by its position in the chunk grid.
public struct TabletopChunkKey: Hashable {
    public let chunkX: Int
    public let chunkZ: Int
    public init(chunkX: Int, chunkZ: Int) {
        self.chunkX = chunkX
        self.chunkZ = chunkZ
    }
}

/// Tracks which chunks currently show real (non-stale, current-generation)
/// atlas art, and derives `atlasReadyCount`/`isStable` from that set rather
/// than a monotonically incrementing counter.
///
/// Why a set instead of a counter: `TabletopChunkBoard.refreshForTilesetChange`
/// re-requests *every* chunk's atlas even though none of them are
/// individually "dirty" by terrain tile value (see
/// `TabletopBoardReconciler.tilesetChanged`). A naive incrementing counter
/// would keep growing across repeated tileset-change refreshes — exceeding
/// `totalChunks` — and would falsely report "stable" throughout the (still
/// procedural-placeholder) refresh window. Marking every affected chunk
/// pending again at the start of a refresh, and only counting the *current*
/// set of ready chunks, keeps `atlasReadyCount` accurate at every point in
/// time: 0/N immediately after a wholesale refresh starts, climbing back to
/// N/N (deduplicated — reapplying the same chunk's readiness twice never
/// double-counts) as each chunk's real atlas actually lands.
public struct TabletopChunkReadinessTracker {
    public var totalChunks: Int
    private var readyKeys: Set<TabletopChunkKey> = []
    /// True once "stable-ready" has been reported for the *current* round of
    /// pending chunks; reset by `markPending` so a later re-stabilization
    /// (e.g. after another tileset-change refresh) reports again instead of
    /// being silenced forever by an earlier stabilization.
    public private(set) var didLogStable = false

    public init(totalChunks: Int) {
        self.totalChunks = totalChunks
    }

    public var atlasReadyCount: Int { readyKeys.count }
    public var isStable: Bool { totalChunks > 0 && atlasReadyCount >= totalChunks }

    /// Marks `key` as no longer showing current real art (e.g. its
    /// generation was just bumped for a rebuild). Idempotent.
    public mutating func markPending(_ key: TabletopChunkKey) {
        readyKeys.remove(key)
        didLogStable = false
    }

    /// Marks `key` as showing current real art. Idempotent — inserting an
    /// already-ready key again (e.g. a duplicate/late callback invocation
    /// that already passed the caller's own stale-generation guard) never
    /// double-counts `atlasReadyCount`.
    ///
    /// Returns `true` exactly once per round: the call that makes the
    /// tracker newly stable, so the caller can log the "stable-ready"
    /// transition exactly once instead of on every subsequent ready chunk.
    @discardableResult
    public mutating func markReady(_ key: TabletopChunkKey) -> Bool {
        readyKeys.insert(key)
        if !didLogStable, isStable {
            didLogStable = true
            return true
        }
        return false
    }
}
