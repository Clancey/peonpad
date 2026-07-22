// EngineTabletopTransport.swift
//
// The concrete production `TabletopTransport`: binds the visionOS tabletop UI
// to a real Stratagus/Wargus engine session through PR #12's versioned C ABI
// (PeonPadTabletopBridge.h) and the Objective-C++ engine host
// (PeonPadEngineHost).
//
// This file is compiled ONLY into the app build (which supplies the bridging
// header); the host live-logic tests never import it. All non-trivial logic —
// snapshot conversion, command lowering, path/argv planning — lives in the
// framework-free, unit-tested files (TabletopSnapshotConverter,
// EngineCommandEncoder, EngineStartupPlan). This file is the thin, untestable
// seam that reads/writes the raw C structs and owns the engine lifecycle.
//
// Nothing here imports SwiftUI, RealityKit, or UIKit.
import Foundation

/// Writes a diagnostic line to stderr (unbuffered), so engine-boot diagnostics
/// from the app interleave with the engine's own stderr output instead of being
/// lost to stdout block-buffering when launched under a pipe.
@inline(__always)
func tabletopEngineLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - C snapshot → EngineSnapshot shim

extension EngineSnapshot {
    /// Reads a retained `PeonPadSnapshot` (opaque C pointer) into the
    /// framework-free `EngineSnapshot`. Does not release the pointer; the
    /// caller owns its reference.
    init(cSnapshot s: OpaquePointer) {
        let width = peonpad_snapshot_map_width(s)
        let height = peonpad_snapshot_map_height(s)

        var terrain: [EngineTerrainCell] = []
        let terrainCount = Int(peonpad_snapshot_terrain_count(s))
        if terrainCount > 0, let ptr = peonpad_snapshot_terrain(s) {
            terrain.reserveCapacity(terrainCount)
            for i in 0..<terrainCount {
                let c = ptr[i]
                terrain.append(EngineTerrainCell(
                    tileIndex: c.tile_index,
                    fogState: c.fog_state,
                    terrainClass: c.terrain_class))
            }
        }

        var units: [EngineUnitRecord] = []
        let unitCount = Int(peonpad_snapshot_unit_count(s))
        if unitCount > 0, let ptr = peonpad_snapshot_units(s) {
            units.reserveCapacity(unitCount)
            for i in 0..<unitCount {
                let u = ptr[i]
                units.append(EngineUnitRecord(
                    id: u.id, owner: u.owner, alive: u.alive, selected: u.selected,
                    facing: u.facing, hp: u.hp, maxHP: u.max_hp,
                    tileX: u.tile_x, tileY: u.tile_y,
                    worldX: u.world_x, worldY: u.world_y, typeID: u.type_id))
            }
        }

        var types: [EngineUnitType] = []
        let typeCount = Int(peonpad_snapshot_unit_type_count(s))
        if typeCount > 0, let ptr = peonpad_snapshot_unit_types(s) {
            types.reserveCapacity(typeCount)
            for i in 0..<typeCount {
                var entry = ptr[i]
                let ident = withUnsafeBytes(of: &entry.ident) { raw -> String in
                    guard let base = raw.baseAddress else { return "" }
                    return String(cString: base.assumingMemoryBound(to: CChar.self))
                }
                types.append(EngineUnitType(typeID: entry.type_id, ident: ident))
            }
        }

        self.init(
            abiVersion: peonpad_snapshot_abi_version(s),
            generation: peonpad_snapshot_generation(s),
            mapWidth: width, mapHeight: height,
            terrain: terrain, units: units, unitTypes: types)
    }
}

// MARK: - Engine transport

public final class EngineTabletopTransport: TabletopTransport, @unchecked Sendable {
    private let host: PeonPadEngineHost
    private let expectedABIVersion: UInt32
    private let pollInterval: UInt64  // nanoseconds

    /// Creates and starts a live engine transport, or returns `nil` when the
    /// data/user paths are not ready. A `nil` result is an explicit failure the
    /// caller surfaces on the board (never a silent demo fallback).
    ///
    /// - Parameters:
    ///   - config: data/user paths, scenario, and executable name.
    ///   - fileManager: injected for testability of the path checks.
    ///   - pollHz: snapshot poll rate (default 30 Hz).
    public init?(
        config: EngineLaunchConfig,
        fileManager: FileManager = .default,
        pollHz: Double = 30
    ) {
        // Validate launch preconditions up front and fail loudly.
        if let error = EngineStartupPlanner.validate(
            config,
            directoryExists: { isDirectory($0, fileManager) },
            fileExists: { fileManager.fileExists(atPath: $0) },
            isWritable: { ensureWritableDirectory($0, fileManager) }
        ) {
            print("[EngineTabletop] ⚠️  cannot start engine: \(error)")
            return nil
        }

        self.expectedABIVersion = kPeonPadTabletopABIVersion
        self.pollInterval = UInt64((1.0 / max(pollHz, 1)) * 1_000_000_000)
        self.host = PeonPadEngineHost()

        let arguments = EngineStartupPlanner.arguments(for: config)
        guard host.start(withArguments: arguments) else {
            print("[EngineTabletop] ⚠️  engine host refused to start")
            return nil
        }
    }

    deinit {
        host.shutdown()
    }

    // MARK: TabletopTransport

    public var snapshots: AsyncStream<TabletopGameplaySnapshot> {
        let expected = expectedABIVersion
        let interval = pollInterval
        return AsyncStream { continuation in
            let task = Task.detached {
                var lastGeneration: UInt64? = nil
                var yielded = 0
                while !Task.isCancelled {
                    if let cSnap = peonpad_tabletop_latest_snapshot() {
                        let engineSnapshot = EngineSnapshot(cSnapshot: cSnap)
                        peonpad_snapshot_release(cSnap)
                        if engineSnapshot.generation != lastGeneration {
                            lastGeneration = engineSnapshot.generation
                            do {
                                let ui = try TabletopSnapshotConverter.convert(
                                    engineSnapshot, expectedABIVersion: expected)
                                // Diagnostic evidence that live engine snapshots
                                // reach the board (first one, then periodically).
                                if yielded == 0 || yielded % 120 == 0 {
                                    tabletopEngineLog("[EngineTabletop] snapshot gen=\(ui.version)/"
                                        + "\(engineSnapshot.generation) "
                                        + "map=\(ui.mapSize.width)x\(ui.mapSize.height) "
                                        + "units=\(ui.units.count) "
                                        + "types=\(engineSnapshot.unitTypes.count)")
                                }
                                yielded += 1
                                continuation.yield(ui)
                            } catch {
                                // Malformed/incompatible snapshot: log and skip
                                // rather than rendering garbage.
                                tabletopEngineLog("[EngineTabletop] ⚠️  dropped snapshot: \(error)")
                            }
                        }
                    }
                    try? await Task.sleep(nanoseconds: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ command: TabletopGameplayCommand) async {
        guard let encoded = EngineCommandEncoder.encode(command) else {
            print("[EngineTabletop] ⚠️  dropped unencodable command: \(command)")
            return
        }
        var cmd = PeonPadCommand()
        cmd.type = encoded.kind.rawValue
        cmd.abi_ver = kPeonPadTabletopABIVersion
        cmd.unit_id = encoded.unitID
        cmd.tile_x = encoded.tileX
        cmd.tile_y = encoded.tileY
        let rc = withUnsafePointer(to: &cmd) { peonpad_tabletop_post_command($0) }
        if rc != 0 {
            print("[EngineTabletop] ⚠️  post_command rejected (rc=\(rc)): \(command)")
        }
    }
}

// MARK: - Launch configuration

/// Resolves the on-device engine launch configuration and constructs the
/// production transport. Kept in the app-only layer because it depends on the
/// bridging types and process/container paths.
public enum PeonPadTabletopLaunch {
    /// The tabletop app's bundle identifier, used to scope the writable user
    /// directory. Matches PEONPAD_TABLETOP_BUNDLE_IDENTIFIER in the build.
    public static let bundleIdentifier = "org.peonpad.visionos.tabletop"

    /// Builds the engine launch configuration from the app container:
    ///   • data: <home>/Documents/wargus-data  (staged, read-only; PR #13)
    ///   • user: <home>/Library/Application Support/<bundle>/user (writable)
    ///   • scenario: PEONPAD_TABLETOP_SCENARIO env override, else a default.
    public static func resolveConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> EngineLaunchConfig {
        let dataOverride = environment["PEONPAD_TABLETOP_DATA_DIR"]
        let dataPath = dataOverride ?? "\(home)/Documents/wargus-data"
        let userPath = environment["PEONPAD_TABLETOP_USER_DIR"]
            ?? "\(home)/Library/Application Support/\(bundleIdentifier)/user"
        let scenario = environment["PEONPAD_TABLETOP_SCENARIO"]
        return EngineLaunchConfig(
            dataPath: dataPath, userPath: userPath, scenario: scenario,
            executableName: "peonpad-tabletop")
    }

    /// Constructs the production engine transport, or `nil` when the engine
    /// cannot start (paths not ready) so the board shows its diagnostic overlay.
    public static func makeEngineTransport() -> EngineTabletopTransport? {
        EngineTabletopTransport(config: resolveConfig())
    }
}


private func isDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
    var isDir: ObjCBool = false
    return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

/// Ensures `path` exists as a writable directory, creating it if needed.
/// Returns whether the directory exists and is writable afterward.
private func ensureWritableDirectory(_ path: String, _ fileManager: FileManager) -> Bool {
    if !isDirectory(path, fileManager) {
        try? fileManager.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    }
    return isDirectory(path, fileManager) && fileManager.isWritableFile(atPath: path)
}
