// TabletopLauncherModel.swift
//
// Framework-independent launcher logic shared by the native SwiftUI app and
// host tests. This file intentionally imports Foundation only.
import Foundation

public enum WargusDataOrigin: String, Equatable {
    case embeddedBundle
    case simulatorDocuments

    public var displayName: String {
        switch self {
        case .embeddedBundle: return "Embedded licensed game data"
        case .simulatorDocuments: return "Developer-injected game data"
        }
    }
}

public struct WargusDataRoot: Equatable {
    public var path: String
    public var origin: WargusDataOrigin

    public init(path: String, origin: WargusDataOrigin) {
        self.path = path
        self.origin = origin
    }
}

public enum WargusDataError: Error, Equatable, CustomStringConvertible {
    case missing(searched: [String])
    case incomplete(path: String, missing: String)
    case noBattlefields(path: String)
    case unreadableMaps(path: String)

    public var description: String {
        switch self {
        case .missing(let searched):
            return "No licensed Wargus game data was found. Searched: \(searched.joined(separator: ", "))."
        case .incomplete(let path, let missing):
            return "The game data at \(path) is incomplete; \(missing) is missing."
        case .noBattlefields(let path):
            return "No supported scenario, ladder, or skirmish battlefields were found under \(path)/maps."
        case .unreadableMaps(let path):
            return "The battlefield directory could not be read at \(path)/maps."
        }
    }
}

public enum WargusDataResolver {
    public static let embeddedRelativePath = "PrivateGameData/wargus"

    private static let requiredFiles = ["scripts/stratagus.lua", "extracted"]
    private static let requiredDirectories = ["graphics", "maps", "sounds"]

    public static func resolve(
        embeddedPath: String?,
        documentsPath: String,
        directoryExists: (String) -> Bool,
        fileExists: (String) -> Bool
    ) -> Result<WargusDataRoot, WargusDataError> {
        var searched: [String] = []
        if let embeddedPath {
            searched.append(embeddedPath)
            if directoryExists(embeddedPath) {
                return validate(
                    WargusDataRoot(path: embeddedPath, origin: .embeddedBundle),
                    directoryExists: directoryExists,
                    fileExists: fileExists)
            }
        }

        searched.append(documentsPath)
        if directoryExists(documentsPath) {
            return validate(
                WargusDataRoot(path: documentsPath, origin: .simulatorDocuments),
                directoryExists: directoryExists,
                fileExists: fileExists)
        }
        return .failure(.missing(searched: searched))
    }

    public static func validate(
        _ root: WargusDataRoot,
        directoryExists: (String) -> Bool,
        fileExists: (String) -> Bool
    ) -> Result<WargusDataRoot, WargusDataError> {
        for relativePath in requiredFiles {
            guard fileExists(join(root.path, relativePath)) else {
                return .failure(.incomplete(path: root.path, missing: relativePath))
            }
        }
        for relativePath in requiredDirectories {
            guard directoryExists(join(root.path, relativePath)) else {
                return .failure(.incomplete(path: root.path, missing: relativePath))
            }
        }
        return .success(root)
    }

    private static func join(_ base: String, _ component: String) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }
}

public enum TabletopMapCategory: String, CaseIterable, Equatable {
    case scenario
    case ladder
    case skirmish

    public var displayName: String {
        switch self {
        case .scenario: return "Campaign Scenarios"
        case .ladder: return "Ladder Battles"
        case .skirmish: return "Skirmish Maps"
        }
    }

    fileprivate var sortOrder: Int {
        switch self {
        case .scenario: return 0
        case .ladder: return 1
        case .skirmish: return 2
        }
    }
}

public struct TabletopBattlefield: Identifiable, Equatable {
    public var id: String { relativePath }
    public var relativePath: String
    public var name: String
    public var category: TabletopMapCategory
    public var playerCount: Int?

    public init(
        relativePath: String,
        name: String,
        category: TabletopMapCategory,
        playerCount: Int? = nil
    ) {
        self.relativePath = relativePath
        self.name = name
        self.category = category
        self.playerCount = playerCount
    }
}

public enum TabletopMapCatalog {
    public static func discover(relativePaths: [String]) -> [TabletopBattlefield] {
        relativePaths.compactMap(makeBattlefield).sorted {
            if $0.category.sortOrder != $1.category.sortOrder {
                return $0.category.sortOrder < $1.category.sortOrder
            }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    public static func makeBattlefield(relativePath rawPath: String) -> TabletopBattlefield? {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 3,
              components[0].lowercased() == "maps",
              !components.contains(".."),
              let category = TabletopMapCategory(rawValue: components[1].lowercased()),
              isSupportedMap(path)
        else {
            return nil
        }

        let filename = String(components.last!)
        let stripped = stripMapExtensions(filename)
        let playerCount = parsePlayerCount(stripped)
        var display = stripped.replacingOccurrences(
            of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        display = display.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !display.isEmpty else { return nil }
        if display == display.lowercased() {
            display = display.localizedCapitalized
        }
        return TabletopBattlefield(
            relativePath: path, name: display, category: category, playerCount: playerCount)
    }

    private static func isSupportedMap(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".smp") || lower.hasSuffix(".smp.gz")
    }

    private static func stripMapExtensions(_ filename: String) -> String {
        var result = filename
        for suffix in [".gz", ".smp", ".pud"] {
            if result.lowercased().hasSuffix(suffix) {
                result.removeLast(suffix.count)
            }
        }
        return result
    }

    private static func parsePlayerCount(_ name: String) -> Int? {
        guard let match = name.range(of: #"^\((\d+)\)"#, options: .regularExpression) else {
            return nil
        }
        let digits = name[match].dropFirst().dropLast()
        return Int(digits)
    }
}

public enum TabletopUpdateRate: String, CaseIterable, Equatable {
    case efficient
    case balanced
    case smooth

    public var displayName: String {
        switch self {
        case .efficient: return "Efficient"
        case .balanced: return "Balanced"
        case .smooth: return "Smooth"
        }
    }

    public var pollHz: Double {
        switch self {
        case .efficient: return 20
        case .balanced: return 30
        case .smooth: return 60
        }
    }
}

public struct TabletopLaunchSettings: Equatable {
    public var playerName: String
    public var updateRate: TabletopUpdateRate

    public init(playerName: String = "Commander", updateRate: TabletopUpdateRate = .balanced) {
        self.playerName = playerName
        self.updateRate = updateRate
    }

    public var normalizedPlayerName: String {
        let printable = playerName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(printable))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(32)
            .description
    }
}

public enum TabletopLauncherPhase: Equatable {
    case unavailable(WargusDataError)
    case ready
    case starting
    case openingImmersive
    case running
    case hidden
    case openFailed(String)
    case startupFailed(String)
}

public enum TabletopLauncherEvent: Equatable {
    case startRequested
    case engineStarted
    case immersiveOpened
    case immersiveOpenFailed(String)
    case returnedToLauncher
    case resumeRequested
}

public enum TabletopLauncherStateMachine {
    public static func transition(
        from phase: TabletopLauncherPhase,
        event: TabletopLauncherEvent
    ) -> TabletopLauncherPhase {
        switch (phase, event) {
        case (.ready, .startRequested):
            return .starting
        case (.starting, .engineStarted):
            return .openingImmersive
        case (.openingImmersive, .immersiveOpened),
             (.hidden, .immersiveOpened),
             (.openFailed, .immersiveOpened):
            return .running
        case (.openingImmersive, .immersiveOpenFailed(let message)),
             (.hidden, .immersiveOpenFailed(let message)),
             (.openFailed, .immersiveOpenFailed(let message)):
            return .openFailed(message)
        case (.running, .returnedToLauncher):
            return .hidden
        case (.hidden, .resumeRequested),
             (.openFailed, .resumeRequested):
            return .openingImmersive
        default:
            return phase
        }
    }
}

public enum TabletopLauncherFileSystem {
    public static func resolveDataRoot(
        bundleResourcePath: String?,
        homePath: String,
        fileManager: FileManager = .default
    ) -> Result<WargusDataRoot, WargusDataError> {
        let embeddedPath = bundleResourcePath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .appendingPathComponent(WargusDataResolver.embeddedRelativePath, isDirectory: true)
                .path
        }
        let documentsPath = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Documents/wargus-data", isDirectory: true).path
        return WargusDataResolver.resolve(
            embeddedPath: embeddedPath,
            documentsPath: documentsPath,
            directoryExists: { isDirectory($0, fileManager: fileManager) },
            fileExists: { fileManager.fileExists(atPath: $0) })
    }

    public static func discoverMaps(
        dataPath: String,
        fileManager: FileManager = .default
    ) -> Result<[TabletopBattlefield], WargusDataError> {
        let mapsURL = URL(fileURLWithPath: dataPath, isDirectory: true)
            .appendingPathComponent("maps", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: mapsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        else {
            return .failure(.unreadableMaps(path: dataPath))
        }

        let rootPrefix = URL(fileURLWithPath: dataPath, isDirectory: true).path + "/"
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard url.path.hasPrefix(rootPrefix),
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                continue
            }
            paths.append(String(url.path.dropFirst(rootPrefix.count)))
        }
        let maps = TabletopMapCatalog.discover(relativePaths: paths)
        return maps.isEmpty ? .failure(.noBattlefields(path: dataPath)) : .success(maps)
    }

    private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
