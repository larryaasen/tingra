//
//  LayerArrangeCommand.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// Which surface a layer menu item was chosen from, for its `tap` name —
/// the ``ShotMenuSurface`` pattern: the menu bar's Layer menu and the layer
/// row's context menu carry the same items (``LayerMenuItems``), and the
/// name says which one the operator reached for.
enum LayerMenuSurface: Sendable {
    /// The menu bar's Layer menu (``LayerCommands``).
    case menuBar

    /// The context menu on a row of the editor's layer list.
    case contextMenu

    /// The suffix the surface appends to an item's tap name.
    var tapSuffix: String {
        switch self {
        case .menuBar: ".menuItem"
        case .contextMenu: ".menu"
        }
    }
}

/// The closed table of the Layer menu's commands — Keynote's Arrange
/// vocabulary and its exact keys, then Duplicate and Delete (ARCHITECTURE.md,
/// "Direct manipulation, drag-to-reorder, and undo in the layer-tree
/// editor"). Deliberately **not** in ``ProductionShortcut``: these are editing
/// keys, and that list is the closed set of keys that change what goes to
/// air, drawn into the settings pane that names them.
enum LayerArrangeCommand: String, CaseIterable, Sendable {
    /// Move the layer to the top of the stack (⇧⌘]).
    case bringToFront

    /// Move the layer one step up (⌘]).
    case bringForward

    /// Move the layer one step down (⌘[).
    case sendBackward

    /// Move the layer to the bottom of the stack (⇧⌘[).
    case sendToBack

    /// Insert a copy directly above the layer (⌘D).
    case duplicate

    /// Remove the layer. No key: the Delete key reaches the editor through
    /// its own delete command on the list and the monitor, where it cannot
    /// swallow a Delete meant for a text field.
    case delete

    /// The key, or nil for a command with no shortcut.
    var key: KeyEquivalent? {
        switch self {
        case .bringToFront, .bringForward: "]"
        case .sendBackward, .sendToBack: "["
        case .duplicate: "d"
        case .delete: nil
        }
    }

    /// The modifiers the key takes.
    var modifiers: EventModifiers {
        switch self {
        case .bringToFront, .sendToBack: [.command, .shift]
        case .bringForward, .sendBackward, .duplicate: .command
        case .delete: []
        }
    }

    /// The shortcut for a menu item, or nil for a command with none.
    var shortcut: KeyboardShortcut? {
        key.map { KeyboardShortcut($0, modifiers: modifiers) }
    }

    /// The item's localized title.
    var title: Text {
        switch self {
        case .bringToFront:
            Text("Bring to Front", comment: "Layer menu item moving the selected layer to the top of the stack")
        case .bringForward:
            Text("Bring Forward", comment: "Layer menu item moving the selected layer one step up the stack")
        case .sendBackward:
            Text("Send Backward", comment: "Layer menu item moving the selected layer one step down the stack")
        case .sendToBack:
            Text("Send to Back", comment: "Layer menu item moving the selected layer to the bottom of the stack")
        case .duplicate:
            Text("Duplicate Layer", comment: "Layer menu item duplicating the selected layer")
        case .delete:
            Text("Delete Layer", comment: "Layer menu item removing the selected layer")
        }
    }

    /// Whether this command starts the menu's second group — Duplicate and
    /// Delete sit under a divider from the four arrange moves.
    var opensGroup: Bool {
        self == .duplicate
    }

    /// The tap name the item reports from a surface.
    ///
    /// - Parameter surface: Where the item was chosen.
    /// - Returns: `layerBringToFront.menuItem`, `layerDelete.menu`, and so on.
    func tapName(from surface: LayerMenuSurface) -> String {
        let base =
            switch self {
            case .bringToFront: "layerBringToFront"
            case .bringForward: "layerBringForward"
            case .sendBackward: "layerSendBackward"
            case .sendToBack: "layerSendToBack"
            case .duplicate: "layerDuplicate"
            case .delete: "layerDelete"
            }
        return base + surface.tapSuffix
    }

    /// Whether the command applies to the layer at an index in a stack of the
    /// given size: nothing applies without a selection, and a move that
    /// would go nowhere — the top layer brought forward — is disabled, the
    /// way Keynote greys Bring to Front on the frontmost object.
    ///
    /// - Parameters:
    ///   - index: The selected layer's bottom-to-top index, or nil for none.
    ///   - count: The number of layers in the stack.
    /// - Returns: Whether the item is enabled.
    func isAvailable(index: Int?, count: Int) -> Bool {
        guard let index, (0..<count).contains(index) else { return false }
        switch self {
        case .bringToFront, .bringForward: return index < count - 1
        case .sendBackward, .sendToBack: return index > 0
        case .duplicate, .delete: return true
        }
    }

    /// Where an arrange move puts the layer, or nil for a command that is
    /// not a move.
    ///
    /// - Parameters:
    ///   - index: The selected layer's bottom-to-top index.
    ///   - count: The number of layers in the stack.
    /// - Returns: The destination index, unclamped for the one-step moves
    ///   (``isAvailable(index:count:)`` already rules the ends out).
    func destination(from index: Int, count: Int) -> Int? {
        switch self {
        case .bringToFront: count - 1
        case .bringForward: index + 1
        case .sendBackward: index - 1
        case .sendToBack: 0
        case .duplicate, .delete: nil
        }
    }
}
