// TabletopGameplaySource.swift
//
// The live-state consumer seam: a `TabletopGameplaySource` publishes versioned
// coherent gameplay snapshots via an `AsyncStream`; a `TabletopCommandSink`
// accepts player intents (selection, legacy movement, exact engine actions,
// targeting, cancellation, and pause state) and forwards them to the backend.
//
// Three concrete implementations are provided:
//
//   DemoTabletopSession   Self-contained: owns its own snapshot state, applies
//                         commands via the deterministic reducer, and publishes
//                         the result. Safe for tests and SwiftUI previews.
//
//   LiveTabletopSession   Production: delegates snapshot publication and
//                         command dispatch to an injectable `TabletopTransport`.
//                         A nil transport is an explicit, logged error condition
//                         that results in an empty stream; the board view
//                         surfaces a diagnostic overlay rather than silently
//                         falling back to demo content.
//
//   AnyTabletopSession    Type-erased wrapper that combines a source and a sink
//                         into a single value for injection through SwiftUI's
//                         @State initializer.
//
// Nothing in this file imports SwiftUI, RealityKit, or UIKit.
import Foundation

// MARK: - Source protocol

/// Publishes versioned coherent gameplay snapshots to the tabletop board.
/// The stream delivers the current snapshot once on subscription (so the UI
/// can render the initial board without waiting for the first engine tick),
/// then again on every state change.
public protocol TabletopGameplaySource: AnyObject, Sendable {
    /// A stream of gameplay snapshots. Cancelling the consuming `Task` is the
    /// correct teardown; the source never retains the caller beyond the
    /// iteration lifetime.
    var snapshots: AsyncStream<TabletopGameplaySnapshot> { get }
}

// MARK: - Sink protocol

/// Receives player intents from gestures and the palette and forwards them to
/// the gameplay backend (local reducer or live transport).
public protocol TabletopCommandSink: AnyObject, Sendable {
    /// Forwards a command. Returns immediately; the backend handles validation
    /// and state mutation asynchronously. Safe to call from any actor.
    func send(_ command: TabletopGameplayCommand)
}

// MARK: - Demo session

/// A self-contained source/sink pair for demo and preview use only.
///
/// Applies commands locally via `TabletopGameplayCommandReducer`, publishes
/// the resulting snapshot via an `AsyncStream`, and never emits transport
/// warnings. Suitable for unit tests, SwiftUI previews, and standalone
/// demos. Production launch must use `LiveTabletopSession`.
public final class DemoTabletopSession: TabletopGameplaySource, TabletopCommandSink,
                                        @unchecked Sendable {
    private var snapshot: TabletopGameplaySnapshot
    private var continuation: AsyncStream<TabletopGameplaySnapshot>.Continuation?
    private let lock = NSLock()

    /// Creates a demo session seeded with the given snapshot (default: the
    /// procedural demo battlefield from `TabletopGameplaySnapshot.demo()`).
    public init(snapshot: TabletopGameplaySnapshot = .demo()) {
        self.snapshot = snapshot
    }

    // MARK: TabletopGameplaySource

    // Monotonic counter used to pair each subscriber with its continuation so
    // the onTermination handler can safely nil out only the *current* value.
    private var continuationGeneration: UInt64 = 0

    public var snapshots: AsyncStream<TabletopGameplaySnapshot> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            // Atomically: finish any existing subscriber's stream, register
            // the new continuation, and capture the current snapshot — all
            // under one lock so no update is missed between registration and
            // the initial yield, and the finished subscriber sees `.nil` from
            // its next `await` rather than freezing indefinitely.
            let (initial, generation): (TabletopGameplaySnapshot, UInt64) = lock.withLock {
                self.continuation?.finish()
                self.continuationGeneration &+= 1
                let gen = self.continuationGeneration
                self.continuation = continuation
                return (self.snapshot, gen)
            }
            // Nil out self.continuation when the consumer cancels, but only
            // if this is still the active subscriber (a newer subscriber may
            // have already replaced it).
            continuation.onTermination = { [weak self, generation] _ in
                self?.lock.withLock {
                    if self?.continuationGeneration == generation {
                        self?.continuation = nil
                    }
                }
            }
            continuation.yield(initial)
        }
    }

    // MARK: TabletopCommandSink

    public func send(_ command: TabletopGameplayCommand) {
        var pendingSnapshot: TabletopGameplaySnapshot?
        var capturedContinuation: AsyncStream<TabletopGameplaySnapshot>.Continuation?

        lock.lock()
        let next = TabletopGameplayCommandReducer.reduce(snapshot, command: command)
        if next != snapshot {
            snapshot = next
            pendingSnapshot = next
            capturedContinuation = continuation
        }
        lock.unlock()

        // Yield outside the lock to prevent potential reentrancy with the
        // AsyncStream's own internal synchronisation.
        if let s = pendingSnapshot {
            capturedContinuation?.yield(s)
        }
    }
}

// MARK: - Live session

/// The production source/sink pair. Wraps a `TabletopTransport` and forwards
/// snapshot publications and commands through it.
///
/// When `transport` is `nil`, `LiveTabletopSession` logs a prominent error
/// and exposes an immediately-finishing stream. The board view detects the
/// empty stream and shows a diagnostic overlay. Commands sent with no
/// transport are also logged and dropped.
///
/// This explicit failure mode (rather than silent demo fallback) is
/// intentional: it makes a missing engine connection visible to developers
/// during integration.
public final class LiveTabletopSession: TabletopGameplaySource, TabletopCommandSink,
                                        @unchecked Sendable {
    private let transport: TabletopTransport?

    /// Creates a live session backed by `transport`. Pass `nil` to get an
    /// explicitly diagnostic (empty-stream) session; pass a real transport
    /// once the engine-side C-ABI is bound.
    public init(transport: TabletopTransport?) {
        self.transport = transport
        if transport == nil {
            // Surface the missing transport loudly at startup so it cannot
            // be missed during integration. No silent fallback to demo state.
            print("""
[TabletopLive] ⚠️  ERROR: no TabletopTransport bound at production launch.
               The tabletop board will be empty until a transport is injected.
               Bind the engine-side C-ABI transport before shipping.
               For standalone demo/preview use DemoTabletopSession instead.
""")
        }
    }

    // MARK: TabletopGameplaySource

    public var snapshots: AsyncStream<TabletopGameplaySnapshot> {
        guard let transport else {
            // Immediately-finishing stream: the board view reads this as
            // "no transport" and surfaces a diagnostic overlay rather than
            // an empty silent board.
            return AsyncStream { continuation in continuation.finish() }
        }
        return transport.snapshots
    }

    // MARK: TabletopCommandSink

    public func send(_ command: TabletopGameplayCommand) {
        guard let transport else {
            print("[TabletopLive] ⚠️  command dropped (no transport): \(command)")
            return
        }
        Task { await transport.send(command) }
    }
}

// MARK: - Type-erased session

/// A type-erased wrapper combining any `TabletopGameplaySource &
/// TabletopCommandSink` into a single concrete class for use in SwiftUI
/// `@State` initializers and other typed storage.
///
/// Initialize once and reuse — each call to `snapshots` returns the
/// underlying session's stream (which may register a single subscriber).
public final class AnyTabletopSession: TabletopGameplaySource, TabletopCommandSink,
                                       @unchecked Sendable {
    private let _source: any TabletopGameplaySource
    private let _sink: any TabletopCommandSink

    public init<S: TabletopGameplaySource & TabletopCommandSink>(_ session: S)
        where S: Sendable
    {
        _source = session
        _sink = session
    }

    public var snapshots: AsyncStream<TabletopGameplaySnapshot> { _source.snapshots }
    public func send(_ command: TabletopGameplayCommand) { _sink.send(command) }
}
