// TabletopEngineLifecycle.swift
//
// Safe native engine lifecycle for the visionOS tabletop app.
//
// The lifecycle manages the state of the C bridge (peonpad_tabletop_init /
// peonpad_tabletop_cleanup) and validates data paths before the engine can
// publish snapshots. It exposes a `stateUpdates` stream so the tabletop board
// can show appropriate UI while the engine initialises.
//
// State machine
// ─────────────
//   .initializing  →  .ready      bridge initialized, paths validated
//   .initializing  →  .error(_)   path unavailable, bridge init failed,
//                                 or startup task cancelled before ready
//   .ready         →  .shutdown   explicit stop() called
//   .error(_)      →  .shutdown   stop() called from error state
//
// Thread safety
// ─────────────
//   start(paths:) and stop() are safe to call from any actor.
//   stateUpdates is safe to iterate from any async context.
//   peonpad_tabletop_init() / peonpad_tabletop_cleanup() are invoked from a
//   dedicated background Task, never from the main actor.
//
// Nothing in this file imports SwiftUI, RealityKit, or UIKit.
import Foundation
#if canImport(PeonPadTabletopBridge)
import PeonPadTabletopBridge
#endif

// MARK: - State

public enum TabletopEngineState: Equatable, Sendable {
    /// Bridge initialization is in progress.
    case initializing
    /// Bridge is initialized and the engine is ready to publish snapshots.
    case ready
    /// Initialization failed. The transport will produce an empty stream.
    /// Callers must surface this error visibly; there is no demo fallback.
    case error(String)
    /// The bridge has been cleaned up. Discard the lifecycle and create a
    /// new one to re-enter `.initializing`.
    case shutdown
}

// MARK: - Lifecycle

/// Manages the C-bridge lifecycle and data-path validation.
///
/// Typical usage:
///
///     let lifecycle = TabletopEngineLifecycle()
///     lifecycle.start(paths: resolvedPaths)   // async; transitions to .ready or .error
///     // … app runs …
///     lifecycle.stop()                        // transitions to .shutdown; bridge cleaned up
///
/// The `TabletopEngineTransport` may be created at any time; it tolerates
/// pre-init bridge state by returning nil snapshots from
/// `peonpad_tabletop_latest_snapshot()` until the bridge is initialized.
public final class TabletopEngineLifecycle: @unchecked Sendable {

    // ── State ─────────────────────────────────────────────────────────────

    private let lock = NSLock()
    private var _state: TabletopEngineState = .initializing
    private var _continuation: AsyncStream<TabletopEngineState>.Continuation?

    // ── Init task ─────────────────────────────────────────────────────────

    /// The background Task that runs the bridge init sequence. Retained so
    /// stop() can cancel it before the transition to .ready.
    private var initTask: Task<Void, Never>?

    // MARK: - Public

    public init() {}

    deinit {
        // Guard against leaked lifecycle objects by cleaning up the bridge.
        // This is a safety net; callers should always call stop() explicitly.
        stop()
    }

    /// An `AsyncStream` of lifecycle state changes. Yields the current state
    /// immediately on subscription, then again on each transition.
    ///
    /// Use this to gate engine-dependent UI: show a loading overlay while
    /// `.initializing`, reveal the live board on `.ready`, surface an error
    /// banner on `.error`, and tear down transport tasks on `.shutdown`.
    public var stateUpdates: AsyncStream<TabletopEngineState> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let current: TabletopEngineState = lock.withLock {
                self._continuation?.finish()
                self._continuation = continuation
                return self._state
            }
            continuation.yield(current)
        }
    }

    /// Current lifecycle state (snapshot, not reactive).
    public var state: TabletopEngineState {
        lock.withLock { _state }
    }

    /// Begins async lifecycle initialisation on a dedicated background thread:
    ///   1. Validates that the game-data directory in `paths` exists.
    ///   2. Calls `peonpad_tabletop_init()` on a background thread.
    ///   3. Transitions to `.ready` or `.error(_)`.
    ///
    /// Calling `start` when not in `.initializing` is a programming error
    /// and is silently ignored (log message emitted). Call `stop()` first
    /// if you need to restart.
    public func start(paths: TabletopDataPaths) {
        let current = lock.withLock { _state }
        guard current == .initializing else {
            print("[TabletopEngineLifecycle] ⚠️  start() called in state \(current); ignored. Call stop() first.")
            return
        }

        initTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Validate game data path before initialising the bridge.
            guard FileManager.default.fileExists(atPath: paths.gameData.path) else {
                self.transition(to: .error(
                    "Game data not found at \(paths.gameData.path). " +
                    "Run stage-visionos-wargus-data.sh + inject-visionos-wargus-data.sh first."))
                return
            }

            // Cancellation check: stop() may have been called while we validated paths.
            guard !Task.isCancelled else {
                self.transition(to: .error("Startup cancelled before bridge initialized."))
                return
            }

#if canImport(PeonPadTabletopBridge)
            let rc = peonpad_tabletop_init()
            guard rc == 0 else {
                self.transition(to: .error(
                    "peonpad_tabletop_init() returned \(rc); " +
                    "bridge may already be initialized by another lifecycle instance."))
                return
            }
#endif

            // Final cancellation check: stop() may have raced with us.
            if Task.isCancelled {
#if canImport(PeonPadTabletopBridge)
                peonpad_tabletop_cleanup()
#endif
                self.transition(to: .error("Startup cancelled after bridge initialized."))
                return
            }

            self.transition(to: .ready)
            print("[TabletopEngineLifecycle] ✅ Engine bridge ready. " +
                  "game data: \(paths.gameData.lastPathComponent)")
        }
    }

    /// Tears down the bridge and transitions to `.shutdown`. Idempotent.
    ///
    /// Cancel any snapshot-consuming Tasks before calling `stop()` to avoid
    /// a brief window where the transport poll loop calls the bridge after
    /// cleanup.
    public func stop() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = initTask
            initTask = nil
            return t
        }
        task?.cancel()

#if canImport(PeonPadTabletopBridge)
        let wasReady = lock.withLock { _state == .ready }
        if wasReady {
            peonpad_tabletop_cleanup()
        }
#endif

        transition(to: .shutdown)
    }

    // MARK: - Private

    private func transition(to next: TabletopEngineState) {
        var continuation: AsyncStream<TabletopEngineState>.Continuation?
        lock.withLock {
            _state = next
            continuation = _continuation
        }
        continuation?.yield(next)
        if case .shutdown = next {
            continuation?.finish()
            lock.withLock { _continuation = nil }
        }
    }
}
