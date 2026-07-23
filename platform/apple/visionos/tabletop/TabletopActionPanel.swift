// TabletopActionPanel.swift
//
// The pure, framework-free model behind the *floating* tabletop action panel.
// It maps a gameplay snapshot's current selection to (a) human-readable context
// text and (b) a fixed, ordered set of action buttons — each with an explicit
// enabled/disabled state and the exact production `TabletopGameplayCommand` it
// forwards through the `TabletopCommandSink`.
//
// Keeping this logic here (no SwiftUI, RealityKit, or visionOS SDK) means the
// panel's action enablement and command forwarding are unit-testable on the
// host Mac, independently of how the panel is presented or where it is mounted
// in the scene. The panel is deliberately *not* parented under the board root
// (see TabletopBoardView), so it stays fixed and tappable while the board is
// panned, rotated, or scaled.
import Foundation

/// The floating action panel's model: selection context + the actions it
/// exposes for the current selection.
public enum TabletopActionPanel {
    /// The stable set of actions the panel can present, in display order.
    public enum Action: String, CaseIterable, Equatable {
        /// Clear the current selection (`deselectAll`).
        case deselect
        /// Order the selected unit to stop its current action (`stopUnit`).
        case stop
        /// Enter "move" intent: while a unit is selected, tapping the board
        /// issues a move order. This item forwards no command itself; it is an
        /// always-honest affordance/label for the tap-to-move interaction the
        /// board already supports, so the panel never implies an action the
        /// engine will not perform.
        case move
    }

    /// One button in the panel: its label, whether it is currently actionable,
    /// and the production command it forwards (nil for the move affordance,
    /// which is realised by a subsequent board tap rather than a direct
    /// command).
    public struct Item: Equatable {
        public var action: Action
        public var title: String
        public var systemImage: String
        public var isEnabled: Bool
        public var command: TabletopGameplayCommand?

        public init(
            action: Action, title: String, systemImage: String,
            isEnabled: Bool, command: TabletopGameplayCommand?
        ) {
            self.action = action
            self.title = title
            self.systemImage = systemImage
            self.isEnabled = isEnabled
            self.command = command
        }
    }

    /// The full panel state for a snapshot: context strings plus the ordered,
    /// enablement-resolved action items.
    public struct Context: Equatable {
        /// Primary line: the selected unit's readable name, or a no-selection
        /// prompt.
        public var title: String
        /// Secondary line: HP + owner for a selection, or a hint otherwise.
        public var subtitle: String
        /// Whether a live unit is currently selected.
        public var hasSelection: Bool
        /// The ordered action buttons, each already resolved to enabled/disabled.
        public var items: [Item]

        public init(title: String, subtitle: String, hasSelection: Bool, items: [Item]) {
            self.title = title
            self.subtitle = subtitle
            self.hasSelection = hasSelection
            self.items = items
        }

        /// The item for a given action, if present.
        public func item(_ action: Action) -> Item? {
            items.first { $0.action == action }
        }
    }

    /// Builds the panel context for the current snapshot. A `nil` snapshot (no
    /// transport yet) yields the no-selection state with every action disabled.
    public static func context(for snapshot: TabletopGameplaySnapshot?) -> Context {
        // Only a *live* selected unit drives an active selection; a dead unit
        // that was selected before it was killed never enables actions.
        let selected = snapshot?.validatedSelectedUnit
        let hasSelection = selected != nil

        let title: String
        let subtitle: String
        if let unit = selected {
            title = displayName(forKind: unit.kind)
            subtitle = "HP \(max(0, unit.hp))/\(max(0, unit.maxHP)) · Player \(unit.owner + 1)"
        } else {
            title = "No unit selected"
            subtitle = "Tap a unit to select it"
        }

        let items: [Item] = [
            Item(action: .deselect, title: "Deselect",
                 systemImage: "xmark.circle",
                 isEnabled: hasSelection,
                 command: hasSelection ? .deselectAll : nil),
            Item(action: .move, title: "Move",
                 systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                 isEnabled: hasSelection,
                 command: nil),
            Item(action: .stop, title: "Stop",
                 systemImage: "stop.circle",
                 isEnabled: hasSelection,
                 command: hasSelection ? .stopUnit(id: selected!.id) : nil),
        ]

        return Context(title: title, subtitle: subtitle,
                       hasSelection: hasSelection, items: items)
    }

    /// Turns an engine unit ident (e.g. `"unit-footman"`, `"unit-great-hall"`)
    /// into a readable title (`"Footman"`, `"Great Hall"`). Empty/procedural
    /// idents fall back to a generic "Unit".
    public static func displayName(forKind kind: String) -> String {
        var name = kind
        if name.hasPrefix("unit-") { name.removeFirst("unit-".count) }
        name = name.replacingOccurrences(of: "-", with: " ")
             .replacingOccurrences(of: "_", with: " ")
        let words = name.split(separator: " ").map { word -> String in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? "Unit" : joined
    }
}
