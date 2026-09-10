//
//  LayerUndoAction.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// What a layer-tree edit did, for the Edit menu's Undo and Redo items —
/// "Undo Move Layer", the way Keynote names every step — and for the
/// `layerEdit.undo` tap that records a restore in the log
/// (ARCHITECTURE.md, "Direct manipulation, drag-to-reorder, and undo in the
/// layer-tree editor"). The raw value is the tap's `action` param.
enum LayerUndoAction: String, CaseIterable, Sendable {
    case moveLayer
    case resizeLayer
    case changeOpacity
    case addLayer
    case removeLayer
    case reorderLayer
    case duplicateLayer
    case addEffect
    case removeEffect
    case moveEffect
    case adjustEffect
    case changeInput

    /// The localized name the Undo and Redo menu items append.
    var title: String {
        switch self {
        case .moveLayer:
            String(localized: "Move Layer", comment: "Undo action name: a layer was moved on the monitor or nudged")
        case .resizeLayer:
            String(localized: "Resize Layer", comment: "Undo action name: a layer's size changed")
        case .changeOpacity:
            String(localized: "Change Opacity", comment: "Undo action name: a layer's opacity changed")
        case .addLayer:
            String(localized: "Add Layer", comment: "Menu adding a layer bound to an input")
        case .removeLayer:
            String(localized: "Remove Layer", comment: "Button removing the selected layer")
        case .reorderLayer:
            String(localized: "Reorder Layer", comment: "Undo action name: a layer moved through the stack")
        case .duplicateLayer:
            String(localized: "Duplicate Layer", comment: "Layer menu item duplicating the selected layer")
        case .addEffect:
            String(localized: "Add Effect", comment: "Menu adding an effect to a channel strip's chain")
        case .removeEffect:
            String(localized: "Remove Effect", comment: "Button removing an effect from a channel strip's chain")
        case .moveEffect:
            String(localized: "Move Effect", comment: "Undo action name: an effect moved through a layer's chain")
        case .adjustEffect:
            String(localized: "Adjust Effect", comment: "Undo action name: an effect parameter changed")
        case .changeInput:
            String(localized: "Change Input", comment: "Undo action name: a layer was rebound to another input")
        }
    }
}
