// TabletopEngineTransport.swift
//
// Concrete production TabletopTransport: binds the visionOS tabletop UI's
// AsyncStream<TabletopGameplaySnapshot> / async command API to the versioned
// pure-C ABI in PeonPadTabletopBridge.h (PR #12).
//
// Snapshot polling
// ────────────────
//   A background Task polls peonpad_tabletop_latest_snapshot() at ~20 Hz.
//   When the generation counter advances (or the first non-nil snapshot
//   arrives), the raw C snapshot is converted to a Swift value and yielded
//   on the AsyncStream. The ABI retain/release contract is honoured: the
//   bridge snapshot is retained before any read, then released via defer
//   once conversion is complete.
//
// ABI validation (convert() returns nil and logs on each violation)
// ─────────────────────────────────────────────────────────────────
//   • peonpad_snapshot_abi_version() != PEONPAD_TABLETOP_ABI_VERSION → drop.
//   • terrain_count != map_width × map_height → drop.
//   • map dimension > PEONPAD_TABLETOP_MAX_MAP_DIM → drop.
//   • unit_count > PEONPAD_TABLETOP_MAX_UNITS → clamp with warning.
//
// Command dispatch
// ────────────────
//   TabletopGameplayCommand values are mapped to PeonPadCommand and posted via
//   peonpad_tabletop_post_command(). Unit IDs are numeric strings when backed
//   by the engine ("42"); non-numeric IDs (e.g. from demo fixtures) are
//   rejected with a log rather than a crash.
//
//   Swift coordinate mapping:
//     TabletopGameplayUnit.tileX  ↔  PeonPadUnitRecord.tile_x  (map column)
//     TabletopGameplayUnit.tileZ  ↔  PeonPadUnitRecord.tile_y  (map row)
//     moveUnit(toTileX:, toTileZ:) ↔  PeonPadCommand.tile_x / tile_y
//
// Nothing in this file imports SwiftUI, RealityKit, or UIKit.
import Foundation

#if canImport(PeonPadTabletopBridge)
import PeonPadTabletopBridge

// MARK: - Engine transport (bridge-linked build)

/// The production `TabletopTransport` backed by the C-ABI bridge.
///
/// Create one instance and inject it into `LiveTabletopSession`. The transport
/// is safe to create before `TabletopEngineLifecycle` has reached `.ready`:
/// the poll loop will return nil snapshots from the bridge until the first
/// one is published, without crashing.
public final class TabletopEngineTransport: TabletopTransport, @unchecked Sendable {

    /// Poll interval: 50 ms ≈ 20 Hz — responsive without excessive CPU load.
    private static let pollIntervalNS: UInt64 = 50_000_000

    public init() {}

    // MARK: TabletopTransport – snapshots

    public var snapshots: AsyncStream<TabletopGameplaySnapshot> {
        AsyncStream { continuation in
            let pollTask = Task.detached(priority: .userInitiated) {
                // UInt64.max is a sentinel meaning "no snapshot observed yet".
                var lastGeneration: UInt64 = .max
                while !Task.isCancelled {
                    if let raw = peonpad_tabletop_latest_snapshot() {
                        defer { peonpad_snapshot_release(raw) }

                        // ABI version guard: drop snapshots from a mismatched build.
                        let abiVer = peonpad_snapshot_abi_version(raw)
                        guard abiVer == PEONPAD_TABLETOP_ABI_VERSION else {
                            print("[TabletopEngineTransport] ⚠️  ABI mismatch: " +
                                  "snapshot version \(abiVer) ≠ expected " +
                                  "\(PEONPAD_TABLETOP_ABI_VERSION). " +
                                  "Relink transport and bridge from the same build.")
                            try? await Task.sleep(nanoseconds: Self.pollIntervalNS)
                            continue
                        }

                        let gen = peonpad_snapshot_generation(raw)
                        if gen != lastGeneration {
                            lastGeneration = gen
                            if let snapshot = Self.convert(raw) {
                                continuation.yield(snapshot)
                            }
                        }
                    }
                    try? await Task.sleep(nanoseconds: Self.pollIntervalNS)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pollTask.cancel() }
        }
    }

    // MARK: TabletopTransport – commands

    public func send(_ command: TabletopGameplayCommand) async {
        var cmd = PeonPadCommand()
        cmd.abi_ver = PEONPAD_TABLETOP_ABI_VERSION

        switch command {
        case .selectUnit(let id):
            guard let uid = Self.parseUnitID(id) else {
                print("[TabletopEngineTransport] ⚠️  selectUnit: non-numeric id '\(id)' dropped.")
                return
            }
            cmd.type = UInt32(PEONPAD_CMD_SELECT.rawValue)
            cmd.unit_id = uid

        case .deselectAll:
            cmd.type = UInt32(PEONPAD_CMD_DESELECT_ALL.rawValue)
            cmd.unit_id = 0

        case .moveUnit(let id, let toTileX, let toTileZ):
            guard let uid = Self.parseUnitID(id) else {
                print("[TabletopEngineTransport] ⚠️  moveUnit: non-numeric id '\(id)' dropped.")
                return
            }
            cmd.type    = UInt32(PEONPAD_CMD_MOVE.rawValue)
            cmd.unit_id = uid
            cmd.tile_x  = Int32(toTileX)
            cmd.tile_y  = Int32(toTileZ)   // Swift tileZ (board row) → C tile_y (map row)

        case .stopUnit(let id):
            guard let uid = Self.parseUnitID(id) else {
                print("[TabletopEngineTransport] ⚠️  stopUnit: non-numeric id '\(id)' dropped.")
                return
            }
            cmd.type = UInt32(PEONPAD_CMD_STOP.rawValue)
            cmd.unit_id = uid
        }

        let rc = withUnsafePointer(to: cmd) { peonpad_tabletop_post_command($0) }
        if rc != 0 {
            print("[TabletopEngineTransport] ⚠️  post_command returned \(rc) for \(command)")
        }
    }

    // MARK: - C → Swift conversion

    /// Converts a retained bridge snapshot (opaque C pointer) into a Swift value.
    ///
    /// The caller is responsible for retaining `raw` before this call and
    /// releasing it when done (`defer { peonpad_snapshot_release(raw) }` is
    /// the required pattern). Returns `nil` and logs on ABI/validation errors.
    ///
    /// `PeonPadSnapshot` is an opaque/incomplete C type; Swift imports
    /// `PeonPadSnapshot *` as `OpaquePointer`. All field access is via the
    /// ABI accessor functions declared in PeonPadTabletopBridge.h.
    ///
    /// `internal` rather than `private` to allow direct unit testing.
    static func convert(_ raw: OpaquePointer) -> TabletopGameplaySnapshot? {

        let mw           = peonpad_snapshot_map_width(raw)
        let mh           = peonpad_snapshot_map_height(raw)
        let terrainCount = peonpad_snapshot_terrain_count(raw)
        let unitCount    = peonpad_snapshot_unit_count(raw)

        // ── Map-dimension guard ───────────────────────────────────────────
        guard mw <= PEONPAD_TABLETOP_MAX_MAP_DIM,
              mh <= PEONPAD_TABLETOP_MAX_MAP_DIM else {
            print("[TabletopEngineTransport] ⚠️  Map \(mw)×\(mh) exceeds limit; dropping.")
            return nil
        }

        // ── Terrain-count coherence guard ─────────────────────────────────
        let expectedCells = UInt64(mw) * UInt64(mh)
        guard UInt64(terrainCount) == expectedCells else {
            print("[TabletopEngineTransport] ⚠️  terrain_count \(terrainCount) ≠ " +
                  "\(mw)×\(mh)=\(expectedCells); dropping.")
            return nil
        }

        // ── Convert terrain and fog ───────────────────────────────────────
        var terrain: [TabletopTerrainTile] = []
        var fogMask: [TabletopFogTile]     = []
        if terrainCount > 0, let cells = peonpad_snapshot_terrain(raw) {
            terrain.reserveCapacity(Int(terrainCount))
            fogMask.reserveCapacity(Int(terrainCount))
            for y in 0..<Int(mh) {
                for x in 0..<Int(mw) {
                    let cell = cells[y * Int(mw) + x]
                    terrain.append(TabletopTerrainTile(
                        tileX: x, tileZ: y,
                        kind: terrainKind(forTileIndex: cell.tile_index)))
                    // fog_state >= EXPLORED means the tile has been seen at some point.
                    fogMask.append(TabletopFogTile(
                        tileX: x, tileZ: y,
                        isRevealed: cell.fog_state >= UInt8(PEONPAD_FOG_EXPLORED.rawValue)))
                }
            }
        }

        // ── Convert units (clamped at ABI limit) ──────────────────────────
        let effectiveUnitCount: Int
        if unitCount > PEONPAD_TABLETOP_MAX_UNITS {
            print("[TabletopEngineTransport] ⚠️  unit_count \(unitCount) > " +
                  "max \(PEONPAD_TABLETOP_MAX_UNITS); clamping.")
            effectiveUnitCount = Int(PEONPAD_TABLETOP_MAX_UNITS)
        } else {
            effectiveUnitCount = Int(unitCount)
        }

        var units: [TabletopGameplayUnit] = []
        var selectionID: String?          = nil

        if effectiveUnitCount > 0, let recs = peonpad_snapshot_units(raw) {
            units.reserveCapacity(effectiveUnitCount)
            for i in 0..<effectiveUnitCount {
                let rec = recs[i]
                let uid = "\(rec.id)"
                // Dead units (alive == 0) are included so the board can
                // animate their removal before discarding them.
                units.append(TabletopGameplayUnit(
                    id: uid,
                    owner: Int(rec.owner),
                    hp: Int(rec.hp),
                    maxHP: Int(rec.max_hp),
                    facingRadians: facingRadians(fromStratagus: rec.facing),
                    tileX: Int(rec.tile_x),
                    tileZ: Int(rec.tile_y)   // C tile_y (map row) → Swift tileZ
                ))
                // First selected unit wins (Stratagus maintains single selection).
                if selectionID == nil && rec.selected != 0 {
                    selectionID = uid
                }
            }
        }

        return TabletopGameplaySnapshot(
            version: TabletopGameplaySnapshot.currentVersion,
            mapSize: TabletopMapSize(width: Int(mw), height: Int(mh)),
            terrain: terrain,
            fogMask: fogMask,
            units: units,
            selection: TabletopGameplaySelection(selectedUnitID: selectionID)
        )
    }

    // MARK: - Private helpers

    /// Converts a Stratagus facing byte (0–255, 0=North clockwise) to radians.
    ///   0   = North (0 rad)
    ///   64  = East  (π/2)
    ///   128 = South (π)
    ///   192 = West  (3π/2)
    static func facingRadians(fromStratagus facing: UInt8) -> Double {
        Double(facing) / 256.0 * 2.0 * .pi
    }

    /// Maps a Stratagus/Wargus tile index to a `TabletopTerrainKind`.
    ///
    /// This is an approximate structural mapping using common Wargus summer-
    /// tileset index ranges. The exact mapping is tileset-dependent and is
    /// owned by the subsequent asset-renderer session; this placeholder gives
    /// the board a non-trivial terrain layout for integration testing.
    ///
    /// TODO(asset-renderer): replace with a proper tileset-aware lookup table
    /// loaded from the staged game data.
    static func terrainKind(forTileIndex index: UInt16) -> TabletopTerrainKind {
        switch index {
        case 0x00..<0x10:  return .grass
        case 0x10..<0x30:  return .dirt
        case 0x30..<0x60:  return .water
        case 0x60..<0x80:  return .rock
        case 0x80..<0xA0:  return .forest
        default:           return .grass
        }
    }

    /// Parses a Swift unit-ID string to a C `uint32_t`.
    ///
    /// Engine-backed transports always produce numeric IDs; non-numeric IDs
    /// indicate a command from the demo layer reaching the production transport
    /// by mistake. Returns nil for those cases (caller logs and drops).
    static func parseUnitID(_ id: String) -> UInt32? {
        UInt32(id)
    }
}

#else // PeonPadTabletopBridge not available (pure-Swift host tests)

// MARK: - Stub transport (no bridge)

/// Placeholder that compiles when the C bridge is not linked (e.g. pure-Swift
/// host test targets). Never instantiated in the visionOS app.
public final class TabletopEngineTransport: TabletopTransport, @unchecked Sendable {
    public init() {}
    public var snapshots: AsyncStream<TabletopGameplaySnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }
    public func send(_ command: TabletopGameplayCommand) async {}
}

#endif // canImport(PeonPadTabletopBridge)
