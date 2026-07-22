// WargusTabletopAssetResolver.swift
//
// A concrete `TabletopAssetResolver` that maps engine-derived terrain kinds
// and unit-type idents (from the live snapshot's unit-type registry) to stable
// resource names for real Wargus-derived art.
//
// No proprietary Warcraft II art is embedded or committed. The resolver only
// produces resource *names*; a resource is returned only when it is present in
// the injected `catalog` (the set of asset names the running app actually has,
// e.g. extracted from the user's staged data at runtime). With an empty
// catalog it behaves exactly like `NullTabletopAssetResolver`, so the board
// falls back to procedural coloring and the build never ships art.
//
// Nothing in this file imports SwiftUI, RealityKit, or UIKit.
import Foundation

public final class WargusTabletopAssetResolver: TabletopAssetResolver, @unchecked Sendable {
    /// The set of resource names actually available to the app at runtime.
    /// Populated from the staged data container; empty in tests and when no
    /// art has been extracted, which yields the procedural fallback.
    private let catalog: Set<String>

    public init(catalog: Set<String> = []) {
        self.catalog = catalog
    }

    // MARK: TabletopAssetResolver

    public func terrainTexture(for kind: TabletopTerrainKind) -> String? {
        gated(Self.terrainResourceName(for: kind))
    }

    public func unitSprite(unitKind: String, canonical: WarcraftCanonicalFacing) -> String? {
        guard let base = Self.unitResourceBase(for: unitKind) else { return nil }
        return gated("\(base).\(Self.facingSuffix(canonical))")
    }

    // MARK: Resource-name mapping (deterministic, art-free)

    /// Stable terrain texture resource name for a UI terrain kind.
    public static func terrainResourceName(for kind: TabletopTerrainKind) -> String {
        "wargus/terrain/\(kind.rawValue)"
    }

    /// Normalizes an engine unit ident (e.g. "unit-footman", "unit-grunt")
    /// into a sprite-sheet base resource name, or `nil` for an empty/unknown
    /// ident so the caller can fall back to a procedural billboard.
    public static func unitResourceBase(for unitKind: String) -> String? {
        let trimmed = unitKind.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Engine idents are conventionally "unit-<name>"; strip the prefix so
        // the resource name is stable regardless of engine naming quirks.
        let name = trimmed.hasPrefix("unit-")
            ? String(trimmed.dropFirst("unit-".count))
            : trimmed
        guard !name.isEmpty else { return nil }
        return "wargus/units/\(name)"
    }

    /// Warcraft II stores five unique facings (N, NE, E, SE, S); the render
    /// layer mirrors them for the remaining three. Map the canonical facing to
    /// a stable frame suffix.
    public static func facingSuffix(_ canonical: WarcraftCanonicalFacing) -> String {
        switch canonical {
        case .north:     return "n"
        case .northEast: return "ne"
        case .east:      return "e"
        case .southEast: return "se"
        case .south:     return "s"
        }
    }

    // MARK: Catalog gating

    /// Returns `name` only when the running app actually has that resource;
    /// otherwise `nil`, so the board uses its procedural fallback and no art is
    /// required at build time.
    private func gated(_ name: String) -> String? {
        catalog.contains(name) ? name : nil
    }
}
