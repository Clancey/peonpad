// TabletopApp.swift
//
// Entry point for the native visionOS tabletop foundation. This is a
// self-contained SwiftUI + RealityKit application, entirely separate from
// the SDL3 smoke shell in platform/apple/visionos and its
// PeonPadVisionShell.app: nothing here touches SDL, UIKit scene delegates,
// or the Designed-for-iPad Warcraft II app. There is no gameplay, no
// Stratagus/Wargus dependency, and no proprietary game data -- this layer
// only proves out the spatial board, billboard, and gesture foundation the
// eventual battlefield will sit on.
import SwiftUI

@main
struct PeonPadTabletopApp: App {
    private static let immersiveSpaceID = "org.peonpad.visionos.tabletop.board-space"

    var body: some SwiftUI.Scene {
        WindowGroup {
            TabletopLauncherView(immersiveSpaceID: Self.immersiveSpaceID)
        }

        ImmersiveSpace(id: Self.immersiveSpaceID) {
            TabletopBoardView()
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

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
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
                break
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
