import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func testPathPrecedenceAndValidation() {
    let embedded = "/App/PrivateGameData/wargus"
    let documents = "/Home/Documents/wargus-data"
    let directories: Set<String> = [
        embedded, "\(embedded)/graphics", "\(embedded)/maps", "\(embedded)/sounds",
        documents, "\(documents)/graphics", "\(documents)/maps", "\(documents)/sounds",
    ]
    let files: Set<String> = [
        "\(embedded)/scripts/stratagus.lua", "\(embedded)/extracted",
        "\(documents)/scripts/stratagus.lua", "\(documents)/extracted",
    ]
    let result = WargusDataResolver.resolve(
        embeddedPath: embedded,
        documentsPath: documents,
        directoryExists: { directories.contains($0) },
        fileExists: { files.contains($0) })
    expect(result == .success(WargusDataRoot(path: embedded, origin: .embeddedBundle)),
           "embedded data takes precedence over Documents")

    let fallback = WargusDataResolver.resolve(
        embeddedPath: embedded,
        documentsPath: documents,
        directoryExists: { $0 != embedded && directories.contains($0) },
        fileExists: { files.contains($0) })
    expect(fallback == .success(WargusDataRoot(path: documents, origin: .simulatorDocuments)),
           "Documents data is the fallback when embedded data is absent")

    let broken = WargusDataResolver.resolve(
        embeddedPath: embedded,
        documentsPath: documents,
        directoryExists: { directories.contains($0) },
        fileExists: { $0 != "\(embedded)/extracted" && files.contains($0) })
    expect(broken == .failure(.incomplete(path: embedded, missing: "extracted")),
           "an invalid embedded bundle fails instead of silently using fallback data")

    let missing = WargusDataResolver.resolve(
        embeddedPath: embedded,
        documentsPath: documents,
        directoryExists: { _ in false },
        fileExists: { _ in false })
    expect(missing == .failure(.missing(searched: [embedded, documents])),
           "missing-data error lists deterministic searched paths")
}

private func testMapDiscovery() {
    let maps = TabletopMapCatalog.discover(relativePaths: [
        "maps/skirmish/multiplayer/(4)just-land.smp",
        "maps/scenario/A Tight Spot BNE.pud.smp.gz",
        "maps/ladder/Garden of war BNE.pud.smp.gz",
        "maps/campaign/not-supported.smp",
        "maps/scenario/readme.txt",
        "../maps/scenario/escape.smp",
    ])
    expect(maps.map(\.relativePath) == [
        "maps/scenario/A Tight Spot BNE.pud.smp.gz",
        "maps/ladder/Garden of war BNE.pud.smp.gz",
        "maps/skirmish/multiplayer/(4)just-land.smp",
    ], "maps are filtered and sorted by category then human name")
    expect(maps.map(\.name) == ["A Tight Spot BNE", "Garden of war BNE", "Just Land"],
           "map filenames become human-friendly names")
    expect(maps.last?.playerCount == 4, "skirmish player count is parsed")
}

private func testSettingsAndArguments() {
    let settings = TabletopLaunchSettings(
        playerName: "  Cmd\u{0000}r  ", updateRate: .smooth)
    expect(settings.normalizedPlayerName == "Cmdr", "player name removes controls and whitespace")
    expect(settings.updateRate.pollHz == 60, "smooth update setting maps to 60 Hz")

    let config = EngineLaunchConfig(
        dataPath: "/d",
        userPath: "/u",
        scenario: "maps/scenario/one.smp",
        playerName: settings.normalizedPlayerName,
        executableName: "peonpad")
    expect(EngineStartupPlanner.arguments(for: config) == [
        "peonpad", "-d", "/d", "-u", "/u", "-N", "Cmdr",
        "maps/scenario/one.smp",
    ], "argv contains app-owned data, user, player, and map arguments")
}

private func testLaunchStateTransitions() {
    var phase: TabletopLauncherPhase = .ready
    phase = TabletopLauncherStateMachine.transition(from: phase, event: .startRequested)
    expect(phase == .starting, "ready transitions to starting")
    phase = TabletopLauncherStateMachine.transition(from: phase, event: .engineStarted)
    expect(phase == .openingImmersive, "engine startup transitions to immersive opening")
    phase = TabletopLauncherStateMachine.transition(from: phase, event: .immersiveOpened)
    expect(phase == .running, "immersive success transitions to running")
    phase = TabletopLauncherStateMachine.transition(from: phase, event: .returnedToLauncher)
    expect(phase == .hidden, "returning to launcher retains the running session")
    phase = TabletopLauncherStateMachine.transition(from: phase, event: .resumeRequested)
    expect(phase == .openingImmersive, "hidden session can resume")
    phase = TabletopLauncherStateMachine.transition(
        from: phase, event: .immersiveOpenFailed("Cancelled"))
    expect(phase == .openFailed("Cancelled"), "immersive error remains an honest running-session error")
    phase = TabletopLauncherStateMachine.transition(
        from: phase, event: .immersiveOpenFailed("Still unavailable"))
    expect(phase == .openFailed("Still unavailable"),
           "repeated immersive failure refreshes the visible error")
    let unchanged = TabletopLauncherStateMachine.transition(
        from: TabletopLauncherPhase.unavailable(.noBattlefields(path: "/d")),
        event: .startRequested)
    expect(unchanged == .unavailable(.noBattlefields(path: "/d")),
           "invalid data cannot transition into engine startup")
}

@main
private enum TabletopLauncherModelTests {
    static func main() {
        testPathPrecedenceAndValidation()
        testMapDiscovery()
        testSettingsAndArguments()
        testLaunchStateTransitions()

        if failures > 0 {
            print("\n\(failures) launcher test(s) failed")
            exit(1)
        }
        print("\nAll launcher tests passed")
    }
}
