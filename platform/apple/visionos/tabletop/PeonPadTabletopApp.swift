import SwiftUI

@main
struct PeonPadTabletopApp: App {
    var body: some Scene {
        WindowGroup {
            TabletopBoardView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.25, height: 0.55, depth: 0.95, in: .meters)
    }
}
