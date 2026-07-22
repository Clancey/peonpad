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

    var body: some View {
        HStack(spacing: 12) {
            Label("Tabletop", systemImage: "square.grid.3x3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: onRecenter) {
                Label("Recenter", systemImage: "arrow.down.to.line.compact")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackgroundEffect()
    }
}
