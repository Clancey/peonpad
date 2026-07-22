// EngineCommandEncoder.swift
//
// Pure, deterministic lowering of a UI `TabletopGameplayCommand` to an
// `EngineCommand` (the C ABI command shape). Unit IDs on the UI side are
// strings; the engine keys on a `uint32` slot id, so encoding can fail if a
// command names a non-numeric id. Failures are explicit (`nil`) rather than
// silently coerced, so the transport can log and drop a bad command.
//
// Nothing in this file imports SwiftUI, RealityKit, UIKit, or C interop.
import Foundation

public enum EngineCommandEncoder {

    /// Lowers a UI command to the engine command ABI shape.
    ///
    /// - Returns: `nil` when the command cannot be represented — e.g. a
    ///   select/move/stop that names a unit id which is not a `uint32`, or a
    ///   move whose target tile is negative or beyond the ABI's hard map
    ///   limit. `deselectAll` always succeeds.
    public static func encode(
        _ command: TabletopGameplayCommand,
        maxMapDim: Int32 = 1024
    ) -> EngineCommand? {
        switch command {
        case .deselectAll:
            return EngineCommand(kind: .deselectAll)

        case .selectUnit(let id):
            guard let unitID = parseUnitID(id) else { return nil }
            return EngineCommand(kind: .select, unitID: unitID)

        case .stopUnit(let id):
            guard let unitID = parseUnitID(id) else { return nil }
            return EngineCommand(kind: .stop, unitID: unitID)

        case .moveUnit(let id, let toTileX, let toTileZ):
            guard let unitID = parseUnitID(id) else { return nil }
            guard let tx = clampTile(toTileX, maxMapDim: maxMapDim),
                  let tz = clampTile(toTileZ, maxMapDim: maxMapDim) else { return nil }
            return EngineCommand(kind: .move, unitID: unitID, tileX: tx, tileY: tz)
        }
    }

    /// Parses a UI unit id string back to the engine's `uint32` slot id.
    /// Returns `nil` for non-numeric or out-of-range ids.
    public static func parseUnitID(_ id: String) -> UInt32? {
        UInt32(id)
    }

    /// Validates a target tile against the ABI's hard map-dimension limit.
    /// The engine additionally rejects tiles outside the *loaded* map, but the
    /// transport enforces the static bound so it never posts a command the
    /// bridge would reject with -2.
    private static func clampTile(_ value: Int, maxMapDim: Int32) -> Int32? {
        guard value >= 0, value < Int(maxMapDim) else { return nil }
        return Int32(value)
    }
}
