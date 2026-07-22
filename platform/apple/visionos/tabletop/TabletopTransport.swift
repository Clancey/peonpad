// TabletopTransport.swift
//
// Transport-neutral seam between the visionOS tabletop UI and the game engine.
// The UI never imports C or SDL directly; instead it depends on the protocols
// below. A concrete binding (e.g. the C-ABI snapshot/command ABI from the
// engine-side session) satisfies these protocols and is injected at app
// startup without any rewrite of the UI layer.
//
// Nothing in this file imports SwiftUI, RealityKit, UIKit, or C interop.
import Foundation

// MARK: - Transport protocol

/// The injectable transport seam between the visionOS tabletop and the game
/// engine. Subscribers iterate `snapshots` to receive versioned coherent
/// state; callers dispatch player intents via `send(_:)`.
///
/// All calls arrive on whatever actor the caller runs on; the transport
/// implementation is responsible for forwarding to its own thread/actor and
/// for ensuring thread safety internally.
///
/// A `nil` transport at production launch is an explicit error condition: the
/// tabletop UI makes it visible to the developer rather than silently
/// pretending to succeed.
public protocol TabletopTransport: AnyObject, Sendable {
    /// An `AsyncStream` of versioned gameplay snapshots published by the
    /// engine. The stream never terminates during normal gameplay; the
    /// consumer's owning `Task` is the correct lifetime scope.
    var snapshots: AsyncStream<TabletopGameplaySnapshot> { get }

    /// Sends a gameplay command to the engine. The engine validates and
    /// optionally accepts the command, then emits an updated snapshot.
    /// This method must be concurrency-safe and may be called from any actor.
    func send(_ command: TabletopGameplayCommand) async
}

// MARK: - Asset resolver seam

/// Transport-neutral seam for resolving terrain and unit texture names to
/// loadable resources. The procedural default (`NullTabletopAssetResolver`)
/// returns `nil` for every query; a real Wargus asset pack would satisfy this
/// protocol and be injected at runtime.
///
/// The resolver returns opaque `String` resource names rather than `URL`s or
/// `Data` blobs so the pure-logic layer never needs to import any image or
/// file-loading framework. No proprietary Warcraft II art is included here.
public protocol TabletopAssetResolver: AnyObject, Sendable {
    /// The texture resource name for a terrain kind, or `nil` to use the
    /// procedural color fallback.
    func terrainTexture(for kind: TabletopTerrainKind) -> String?

    /// The sprite-sheet resource name for a unit at the given canonical
    /// facing direction, or `nil` to use the procedural billboard fallback.
    /// `unitKind` is an engine-defined type identifier string (e.g.
    /// `"footman"`, `"grunt"`); the resolver is responsible for the mapping.
    func unitSprite(unitKind: String, canonical: WarcraftCanonicalFacing) -> String?
}

// MARK: - Null asset resolver

/// The default asset resolver: always returns `nil`. The board uses
/// procedural coloring for every terrain kind and unit direction.
/// No proprietary art is bundled; this is the compile-time-safe fallback.
public final class NullTabletopAssetResolver: TabletopAssetResolver, @unchecked Sendable {
    public init() {}
    public func terrainTexture(for kind: TabletopTerrainKind) -> String? { nil }
    public func unitSprite(unitKind: String, canonical: WarcraftCanonicalFacing) -> String? { nil }
}
