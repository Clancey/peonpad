// TabletopApp.swift
//
// Native visionOS launcher and immersive tabletop lifecycle. The engine is
// deliberately single-shot: it is created only after a validated battlefield
// selection and remains alive if the user returns to this launcher.
import SwiftUI

@MainActor
final class TabletopAppModel: ObservableObject {
    @Published private(set) var phase: TabletopLauncherPhase
    @Published var selectedMapID: String?
    @Published var settings = TabletopLaunchSettings()

    let dataRoot: WargusDataRoot?
    let maps: [TabletopBattlefield]
    private(set) var launchConfig: EngineLaunchConfig?
    private(set) var engineTransport: EngineTabletopTransport?
    private(set) var gameplaySession: LiveTabletopSession?

    init(
        bundleResourcePath: String? = Bundle.main.resourcePath,
        homePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        switch TabletopLauncherFileSystem.resolveDataRoot(
            bundleResourcePath: bundleResourcePath,
            homePath: homePath,
            fileManager: fileManager)
        {
        case .failure(let error):
            dataRoot = nil
            maps = []
            selectedMapID = nil
            phase = .unavailable(error)
        case .success(let root):
            dataRoot = root
            switch TabletopLauncherFileSystem.discoverMaps(
                dataPath: root.path, fileManager: fileManager)
            {
            case .failure(let error):
                maps = []
                selectedMapID = nil
                phase = .unavailable(error)
            case .success(let discoveredMaps):
                maps = discoveredMaps
                selectedMapID = discoveredMaps.first?.id
                phase = .ready
            }
        }
    }

    var selectedMap: TabletopBattlefield? {
        maps.first { $0.id == selectedMapID }
    }

    var sourceDescription: String {
        dataRoot?.origin.displayName ?? "No game data"
    }

    @discardableResult
    func startEngine() -> Bool {
        guard phase == .ready,
              let dataRoot,
              let selectedMap
        else {
            return false
        }
        phase = TabletopLauncherStateMachine.transition(
            from: phase, event: .startRequested)
        let config = PeonPadTabletopLaunch.resolveConfig(
            dataRoot: dataRoot, battlefield: selectedMap, settings: settings)
        guard let transport = EngineTabletopTransport(
            config: config, pollHz: settings.updateRate.pollHz)
        else {
            phase = .startupFailed(
                "The game engine could not start. Close PeonPad and reopen it before trying again.")
            return false
        }
        launchConfig = config
        engineTransport = transport
        gameplaySession = LiveTabletopSession(transport: transport)
        phase = TabletopLauncherStateMachine.transition(
            from: phase, event: .engineStarted)
        return true
    }

    func markImmersiveOpened() {
        phase = TabletopLauncherStateMachine.transition(
            from: phase, event: .immersiveOpened)
    }

    func markImmersiveOpenFailed(_ message: String) {
        phase = TabletopLauncherStateMachine.transition(
            from: phase, event: .immersiveOpenFailed(message))
    }

    func markReturnedToLauncher() {
        phase = TabletopLauncherStateMachine.transition(
            from: phase, event: .returnedToLauncher)
    }

    func requestResume() {
        phase = TabletopLauncherStateMachine.transition(
            from: phase, event: .resumeRequested)
    }
}

@main
struct PeonPadTabletopApp: App {
    private static let immersiveSpaceID = "org.peonpad.visionos.tabletop.board-space"
    private static let launcherWindowID = "org.peonpad.visionos.tabletop.launcher"

    @StateObject private var model = TabletopAppModel()

    var body: some SwiftUI.Scene {
        WindowGroup(id: Self.launcherWindowID) {
            TabletopLauncherView(
                model: model,
                immersiveSpaceID: Self.immersiveSpaceID,
                launcherWindowID: Self.launcherWindowID)
        }
        .defaultSize(width: 940, height: 620)

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            if let session = model.gameplaySession,
               let config = model.launchConfig
            {
                TabletopBoardView(
                    session: session,
                    harnessTransport: model.engineTransport,
                    launchConfig: config,
                    launcherWindowID: Self.launcherWindowID,
                    onReturnToLauncher: model.markReturnedToLauncher)
            } else {
                ContentUnavailableView(
                    "No Battlefield Running",
                    systemImage: "map",
                    description: Text("Choose a battlefield in the PeonPad launcher first."))
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

struct TabletopLauncherView: View {
    @ObservedObject var model: TabletopAppModel
    let immersiveSpaceID: String
    let launcherWindowID: String

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch model.phase {
            case .unavailable(let error):
                missingDataView(error)
            case .ready:
                readyView
            case .starting:
                progressView("Starting the game engine…")
            case .openingImmersive:
                progressView("Opening your battlefield…")
            case .running:
                battlefieldOpenView
            case .hidden:
                runningSessionView(message: nil)
            case .openFailed(let message):
                runningSessionView(message: message)
            case .startupFailed(let message):
                terminalErrorView(message)
            }
        }
        .padding(28)
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PeonPad")
                        .font(.largeTitle.bold())
                    Text("Choose your battlefield")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.sourceDescription, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }

            HStack(alignment: .top, spacing: 24) {
                battlefieldList
                Divider()
                launchSettings
            }
        }
    }

    private var battlefieldList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Battlefields", systemImage: "map.fill")
                .font(.headline)
            List(selection: $model.selectedMapID) {
                ForEach(TabletopMapCategory.allCases, id: \.self) { category in
                    let categoryMaps = model.maps.filter { $0.category == category }
                    if !categoryMaps.isEmpty {
                        Section(category.displayName) {
                            ForEach(categoryMaps) { map in
                                HStack {
                                    Text(map.name)
                                    Spacer()
                                    if let players = map.playerCount {
                                        Text("\(players)P")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(map.id)
                                .accessibilityIdentifier("launcher.map.\(map.id)")
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 470, minHeight: 410)
        }
    }

    private var launchSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Game Settings", systemImage: "slider.horizontal.3")
                .font(.headline)

            if let selectedMap = model.selectedMap {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedMap.name)
                        .font(.title2.bold())
                    Text(selectedMap.category.displayName)
                        .foregroundStyle(.secondary)
                    if let players = selectedMap.playerCount {
                        Text("Designed for \(players) players")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            TextField("Player name", text: $model.settings.playerName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("launcher.player-name")
            if model.settings.normalizedPlayerName.isEmpty {
                Text("Player name is required.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Picker("Board updates", selection: $model.settings.updateRate) {
                ForEach(TabletopUpdateRate.allCases, id: \.self) { rate in
                    Text(rate.displayName).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("launcher.update-rate")

            Text("Update rate changes how often the native board reads engine state. It does not alter game rules.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
            Button {
                start()
            } label: {
                Label("Launch Battlefield", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                model.selectedMap == nil
                    || model.settings.normalizedPlayerName.isEmpty)
            .accessibilityIdentifier("launcher.launch")
        }
        .frame(minWidth: 330, maxWidth: 360, minHeight: 410)
    }

    private func missingDataView(_ error: WargusDataError) -> some View {
        ContentUnavailableView {
            Label("Game Data Required", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(error.description)
        } actions: {
            Text("Install a private build containing your licensed extracted Wargus data, or inject data into Documents for development.")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("launcher.data-error")
    }

    private func progressView(_ title: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var battlefieldOpenView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Battlefield is open")
                .font(.title3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runningSessionView(message: String?) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Battlefield Session Is Still Running")
                .font(.title.bold())
            Text(message ?? "The immersive board was closed, but the engine remains active.")
                .foregroundStyle(message == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center)
            Text("PeonPad supports one game per app launch. To choose a different map, close and reopen the app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                resume()
            } label: {
                Label("Resume Battlefield", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("launcher.resume")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func terminalErrorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Could Not Start", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        }
    }

    private func start() {
        guard model.startEngine() else { return }
        openBoard()
    }

    private func resume() {
        model.requestResume()
        openBoard()
    }

    private func openBoard() {
        Task {
            let result = await openImmersiveSpace(id: immersiveSpaceID)
            switch result {
            case .opened:
                model.markImmersiveOpened()
                dismissWindow(id: launcherWindowID)
            case .error:
                model.markImmersiveOpenFailed(
                    "visionOS could not open the immersive battlefield. The engine is still running.")
            case .userCancelled:
                model.markImmersiveOpenFailed(
                    "Opening the immersive battlefield was cancelled. The engine is still running.")
            @unknown default:
                model.markImmersiveOpenFailed(
                    "visionOS returned an unknown immersive-space result. The engine is still running.")
            }
        }
    }
}
