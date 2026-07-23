// TabletopActionPanelView.swift
//
// The *floating* tabletop action panel. Unlike the former board-attached
// palette, this view is mounted as a RealityKit attachment that is NOT parented
// under the board root (see TabletopBoardView), so it stays fixed, readable, and
// tappable while the board is panned, rotated, or scaled beneath it.
//
// It renders the current selection context and forwards the applicable
// production commands through the injected sink closure (the exact
// `TabletopCommandSink.send`). Disabled/unavailable actions are shown
// explicitly, and the move affordance is a status chip (not a button) because
// the move order is realised by a subsequent board tap rather than a direct
// command, so the panel never implies an action the engine will not perform.
import SwiftUI

struct TabletopActionPanelView: View {
    static let attachmentID = "org.peonpad.visionos.tabletop.actionpanel"

    /// The resolved panel context (selection text + enablement-resolved items).
    let context: TabletopActionPanel.Context
    /// Forwards a production command through the session's `TabletopCommandSink`.
    let onCommand: (TabletopGameplayCommand) -> Void
    /// Re-centres the board in front of the viewer.
    let onRecenter: () -> Void

    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            actions
            Divider()
            navigation
            if showHelp { helpText }
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
        .glassBackgroundEffect()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(context.title, systemImage: context.hasSelection ? "person.fill" : "hand.tap")
                .font(.headline)
            Text(context.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            ForEach(context.items, id: \.action) { item in
                if item.action == .move {
                    // Move affordance: a status chip, not a button, since the
                    // order is issued by a board tap. Dimmed when unavailable.
                    Label(item.title, systemImage: item.systemImage)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                        .opacity(item.isEnabled ? 1 : 0.4)
                        .accessibilityIdentifier("tabletop.action.\(item.action.rawValue)")
                        .help(item.isEnabled
                              ? "Tap the board to move the selected unit"
                              : "Select a unit first")
                } else {
                    // Command action: a real button that forwards its production
                    // command, explicitly disabled when unavailable.
                    Button {
                        if let command = item.command { onCommand(command) }
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!item.isEnabled || item.command == nil)
                    .accessibilityIdentifier("tabletop.action.\(item.action.rawValue)")
                }
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 10) {
            Button(action: onRecenter) {
                Label("Recenter", systemImage: "arrow.down.to.line.compact")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("tabletop.nav.recenter")
            Button {
                showHelp.toggle()
            } label: {
                Label("Controls", systemImage: "questionmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("Show navigation controls")
            .accessibilityIdentifier("tabletop.nav.help")
        }
    }

    private var helpText: some View {
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
