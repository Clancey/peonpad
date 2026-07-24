// EngineStartupPlan.swift
//
// Pure, deterministic validation and argv construction for booting the
// Stratagus engine from the visionOS tabletop app. The engine must only be
// started once a validated game-data path and a writable user/config/save/log
// path are available; this file encodes those preconditions and the exact
// command line, framework-free and unit-tested on the host Mac.
//
// The engine CLI (engine/stratagus/src/stratagus/stratagus.cpp) is:
//     stratagus [OPTIONS] [map.smp]
//       -d <datapath>   game data directory   (StratagusLibPath)
//       -u <userpath>   writable user directory (config/saves/logs)
//   trailing arg        map, relative to the data path
//
// Nothing in this file imports SwiftUI, RealityKit, UIKit, or C interop.
import Foundation

/// Where the engine reads game data and where it may write. Paths are absolute
/// on-device paths (the data path is the staged, read-only Wargus data from
/// PR #13; the user path is a separate writable container directory).
public struct EngineLaunchConfig: Equatable {
    /// Read-only staged Wargus data directory (contains scripts/stratagus.lua).
    public var dataPath: String
    /// Writable user directory for config, saves, and logs. Kept separate from
    /// the read-only data path so the engine never writes into game data.
    public var userPath: String
    /// Map to load, relative to `dataPath` (e.g. "maps/…/scenario.smp").
    /// When nil the engine boots to its menu (not used for automated launch).
    public var scenario: String?
    /// Player name shown by the engine. Empty names omit the `-N` option.
    public var playerName: String
    /// argv[0] the engine sees; only affects logging/usage text.
    public var executableName: String

    public init(
        dataPath: String,
        userPath: String,
        scenario: String? = nil,
        playerName: String = "",
        executableName: String = "peonpad-tabletop"
    ) {
        self.dataPath = dataPath
        self.userPath = userPath
        self.scenario = scenario
        self.playerName = playerName
        self.executableName = executableName
    }
}

/// Why the engine cannot be started yet. Surfaced to the UI as a visible
/// failure (never a silent fallback to demo gameplay).
public enum EngineStartupError: Error, Equatable {
    /// The staged data directory does not exist on device.
    case dataPathMissing(path: String)
    /// The data directory exists but is missing the Wargus entry script,
    /// meaning game data was never staged/extracted.
    case dataPathIncomplete(path: String, missing: String)
    /// The writable user directory is not writable (cannot save/config/log).
    case userPathNotWritable(path: String)
}

/// Validates launch preconditions and builds the engine argv. All filesystem
/// access is injected so the planner is deterministic and host-testable.
public enum EngineStartupPlanner {

    /// The relative path, under the data directory, that must exist for the
    /// staged Wargus data to be usable.
    public static let requiredEntryScript = "scripts/stratagus.lua"

    /// Validates that data and user paths are ready. Returns `nil` when the
    /// engine may start, or the first blocking error.
    public static func validate(
        _ config: EngineLaunchConfig,
        directoryExists: (String) -> Bool,
        fileExists: (String) -> Bool,
        isWritable: (String) -> Bool
    ) -> EngineStartupError? {
        guard directoryExists(config.dataPath) else {
            return .dataPathMissing(path: config.dataPath)
        }
        let entry = joinPath(config.dataPath, requiredEntryScript)
        guard fileExists(entry) else {
            return .dataPathIncomplete(path: config.dataPath, missing: requiredEntryScript)
        }
        guard isWritable(config.userPath) else {
            return .userPathNotWritable(path: config.userPath)
        }
        return nil
    }

    /// Builds the engine command-line argument vector.
    public static func arguments(for config: EngineLaunchConfig) -> [String] {
        var args = [config.executableName, "-d", config.dataPath, "-u", config.userPath]
        if !config.playerName.isEmpty {
            args.append(contentsOf: ["-N", config.playerName])
        }
        if let scenario = config.scenario, !scenario.isEmpty {
            args.append(scenario)
        }
        return args
    }

    /// Joins two path components with a single separator, tolerating a trailing
    /// slash on the base.
    public static func joinPath(_ base: String, _ component: String) -> String {
        if base.hasSuffix("/") { return base + component }
        return base + "/" + component
    }
}
