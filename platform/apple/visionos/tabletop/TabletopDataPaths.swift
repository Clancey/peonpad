// TabletopDataPaths.swift
//
// Resolves the read-only game-data path and the writable user/config/save/log
// path for the visionOS tabletop engine.
//
// Production rules
// ────────────────
//   • Game data is staged by scripts/stage-visionos-wargus-data.sh (PR #13)
//     and injected by scripts/inject-visionos-wargus-data.sh into the app's
//     data container at Documents/wargus-data/.
//   • User/config/save/log data goes to Library/Application Support/PeonPad/
//     and is created on first use if absent.
//   • Both paths fail with a visible, logged error when unavailable.
//     There is NO silent fallback to demo state.
//
// Nothing in this file imports SwiftUI, RealityKit, or UIKit.
import Foundation

/// Resolved, validated paths used by the tabletop engine at runtime.
public struct TabletopDataPaths: Equatable {
    /// Read-only staged Wargus game data (injected via the PR #13 pipeline).
    /// In the simulator: always at Documents/wargus-data/ in the app's data
    /// container after running inject-visionos-wargus-data.sh.
    public let gameData: URL
    /// Writable user/config/save/log directory, sandboxed to this app.
    public let userData: URL

    // MARK: - Errors

    public enum ResolveError: Error, CustomStringConvertible {
        /// Staged game data does not exist at the expected container path.
        case gameDataUnavailable(path: String)
        /// The writable user-data directory could not be created.
        case userDataInaccessible(path: String, underlying: Error)

        public var description: String {
            switch self {
            case .gameDataUnavailable(let path):
                return """
[TabletopDataPaths] ❌ Game data not found at: \(path)
  Inject staged data first:
    PEONPAD_WARGUS_DATA_DIR=<src> ./scripts/stage-visionos-wargus-data.sh
    ./scripts/inject-visionos-wargus-data.sh
"""
            case .userDataInaccessible(let path, let err):
                return "[TabletopDataPaths] ❌ Cannot create user-data directory \(path): \(err)"
            }
        }
    }

    // MARK: - Production resolution

    /// Resolves and validates production data paths.
    ///
    /// Throws `ResolveError.gameDataUnavailable` when the staged Wargus data
    /// directory is absent — game data must be injected by the PR #13 script
    /// before calling this. Production must never substitute demo state for a
    /// missing path; callers must surface this error visibly.
    public static func resolve() throws -> TabletopDataPaths {
        let fm = FileManager.default

        // ── Game data (read-only) ─────────────────────────────────────────
        let gameDataURL = gameDataPath()
        guard fm.fileExists(atPath: gameDataURL.path) else {
            throw ResolveError.gameDataUnavailable(path: gameDataURL.path)
        }

        // ── User data (writable) ──────────────────────────────────────────
        let userDataURL = userDataPath()
        do {
            try fm.createDirectory(at: userDataURL,
                                   withIntermediateDirectories: true,
                                   attributes: nil)
        } catch {
            throw ResolveError.userDataInaccessible(path: userDataURL.path,
                                                    underlying: error)
        }

        return TabletopDataPaths(gameData: gameDataURL, userData: userDataURL)
    }

    // MARK: - Path factories (internal, exposed for tests)

    /// Game-data path: `Documents/wargus-data/` in the app's data container.
    /// This is the destination written by inject-visionos-wargus-data.sh.
    static func gameDataPath() -> URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("wargus-data", isDirectory: true)
    }

    /// User-data path: `Library/Application Support/PeonPad/` — sandboxed,
    /// writable, persists across app launches.
    static func userDataPath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("PeonPad", isDirectory: true)
    }
}
