// TabletopApp.swift
//
// Entry point for the native visionOS tabletop. This is a self-contained
// SwiftUI + RealityKit application, entirely separate from the SDL3 smoke
// shell: nothing here touches SDL, UIKit scene delegates, or the
// Designed-for-iPad Warcraft II app.
//
// Engine wiring
// ─────────────
//   `TabletopAppCore` bundles the lifecycle, transport, and gameplay session
//   so all three share the same object graph. The lifecycle is started on
//   scene appear after validating the staged game-data path (PR #13); the
//   transport poll loop begins immediately and will yield snapshots once the
//   bridge publishes its first one.
//
//   If the game-data path is unavailable (data not injected via
//   inject-visionos-wargus-data.sh), the lifecycle transitions to .error
//   and the board shows the no-transport diagnostic overlay. There is no
//   silent fallback to the procedural demo state in production.
import SwiftUI

// MARK: - App core (lifecycle + transport + session)

/// Bundles the engine lifecycle, transport, and gameplay session so they share
/// the same object graph for the app's lifetime. Stored in @State so it
/// survives scene recomposition.
private final class TabletopAppCore: @unchecked Sendable {
    let lifecycle  = TabletopEngineLifecycle()
    let transport  = TabletopEngineTransport()
    let session:     LiveTabletopSession

    init() {
        session = LiveTabletopSession(transport: transport)
    }

    /// Resolves production data paths and starts the engine lifecycle.
    /// Errors are logged and surfaced via the lifecycle's `.error` state;
    /// the board view shows a diagnostic overlay rather than demo content.
    func start() async {
        do {
            let paths = try TabletopDataPaths.resolve()
            lifecycle.start(paths: paths)
        } catch {
            print("[TabletopApp] ❌ Data path resolution failed: \(error)")
            // The lifecycle stays in .initializing and will never reach .ready,
            // so LiveTabletopSession produces an empty stream and the board
            // view surfaces the no-transport overlay without crashing.
        }
    }

    func stop() {
        lifecycle.stop()
    }
}

// MARK: - App

@main
struct PeonPadTabletopApp: App {
    private static let immersiveSpaceID = "org.peonpad.visionos.tabletop.board-space"
    private static let launcherWindowID = "org.peonpad.visionos.tabletop.launcher"

    @State private var appCore = TabletopAppCore()

    var body: some SwiftUI.Scene {
        WindowGroup(id: Self.launcherWindowID) {
            TabletopLauncherView(
                immersiveSpaceID: Self.immersiveSpaceID,
                launcherWindowID: Self.launcherWindowID
            )
            .task { await appCore.start() }
        }

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            TabletopBoardView(session: appCore.session)
                .onDisappear { appCore.stop() }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

/// A small 2D window that opens the immersive tabletop space. visionOS apps
/// need at least one window scene; this launcher is deliberately minimal and
/// is not the "persistent head-locked UI" the product direction rules out --
/// once the immersive space opens, all controls live on the board-attached
/// palette instead.
struct TabletopLauncherView: View {
    let immersiveSpaceID: String
    let launcherWindowID: String

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isOpening = false
    @State private var openFailed = false

    var body: some View {
        VStack(spacing: 16) {
            Text("PeonPad Tabletop")
                .font(.largeTitle)
            Text("A placeable battlefield board, viewed and manipulated in your space.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if openFailed {
                Text("Could not open the tabletop space. Try again.")
                    .foregroundStyle(.red)
            }
            Button(isOpening ? "Opening…" : "Open Tabletop") {
                requestOpen()
            }
            .disabled(isOpening)
        }
        .padding(32)
        .task {
            // Automatically enter the immersive board on launch so the
            // spatial foundation is what a user (and automated evidence
            // capture) sees first, rather than a flat launcher screen.
            requestOpen()
        }
    }

    private func requestOpen() {
        guard !isOpening else { return }
        isOpening = true
        openFailed = false
        Task {
            let result = await openImmersiveSpace(id: immersiveSpaceID)
            isOpening = false
            switch result {
            case .opened:
                dismissWindow(id: launcherWindowID)
            case .error:
                print("[Tabletop] immersive space open returned .error")
                openFailed = true
            case .userCancelled:
                print("[Tabletop] immersive space open returned .userCancelled")
                openFailed = true
            @unknown default:
                print("[Tabletop] immersive space open returned unknown result")
                openFailed = true
            }
        }
    }
}
