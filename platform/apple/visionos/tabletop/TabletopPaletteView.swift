// TabletopPaletteView.swift
//
// The board-attached control palette. This view is only ever rendered as a
// RealityKit attachment anchored near the player-facing edge of the board
// (see TabletopBoardView), never as a head-locked overlay window -- per the
// product direction, native controls/status must live in world space next
// to the board they act on.
import SwiftUI

struct TabletopPaletteView: View {
    static let attachmentID = "org.peonpad.visionos.tabletop.palette"

    let onRecenter: () -> Void

    @State private var showHelp = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Label("Tabletop", systemImage: "square.grid.3x3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: onRecenter) {
                    Label("Recenter", systemImage: "arrow.down.to.line.compact")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    showHelp.toggle()
                } label: {
                    Label("Controls", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Show navigation controls")
            }
            if showHelp {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drag to move · pinch to zoom · rotate to turn")
                    Text("(trackpad/mouse in the Simulator; hands on device)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .multilineTextAlignment(.leading)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackgroundEffect()
    }
}
