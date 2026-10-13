//
//  LayerMenuItems.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// The Layer menu's items — Bring to Front, Bring Forward, Send Backward,
/// Send to Back, then Duplicate Layer and Delete Layer — drawn once for the
/// menu bar's Layer menu (``LayerCommands``) and for a layer row's context
/// menu, each reporting the surface it was chosen from
/// (``LayerArrangeCommand``, ``LayerMenuSurface``; ARCHITECTURE.md, "Direct
/// manipulation, drag-to-reorder, and undo in the layer-tree editor").
///
/// The items act on one layer: the row's, for a context menu, or the
/// selection, for the menu bar — and an item that would go nowhere is
/// disabled rather than hidden, the menu-bar convention.
struct LayerMenuItems: View {
    /// The engine model the items edit through, and report their `tap` to.
    @Bindable var model: EngineModel

    /// Which surface the items are drawn on, for their tap names.
    let surface: LayerMenuSurface

    /// The bottom-to-top index of the layer the items act on, or nil for no
    /// layer (every item disabled).
    let index: Int?

    /// The items, in their two groups.
    var body: some View {
        let count = model.editedShot?.shot.layers.count ?? 0
        ForEach(LayerArrangeCommand.allCases, id: \.self) { command in
            if command.opensGroup {
                Divider()
            }
            Button(role: command == .delete ? .destructive : nil) {
                perform(command, count: count)
            } label: {
                command.title
            }
            .keyboardShortcut(command.shortcut(on: surface))
            .disabled(!command.isAvailable(index: index, count: count))
        }
    }

    /// Runs one command on the layer, reporting the `tap` first, and moves
    /// the selection with the layer so a second press keeps acting on the
    /// same one.
    ///
    /// - Parameters:
    ///   - command: The command chosen.
    ///   - count: The number of layers in the stack.
    private func perform(_ command: LayerArrangeCommand, count: Int) {
        guard let index else { return }
        model.eventBus.tap(command.tapName(from: surface), domain: .composition, params: ["index": .int(index)])
        switch command {
        case .bringToFront, .bringForward, .sendBackward, .sendToBack:
            guard let destination = command.destination(from: index, count: count) else { return }
            model.moveLayer(at: index, to: destination)
            model.selectedLayerIndex = min(max(destination, 0), count - 1)
        case .duplicate:
            model.duplicateLayer(at: index)
            model.selectedLayerIndex = index + 1
        case .delete:
            model.selectedLayerIndex = nil
            Task { await model.removeLayer(at: index) }
        }
    }
}

/// The layer list's **Copy Layer** and **Paste Layer** context-menu items:
/// the Edit menu's Copy and Paste where the pointer already is
/// (ARCHITECTURE.md, "Copying a layer between shots"). Context menu only —
/// the menu bar has them in the Edit menu, under ⌘C and ⌘V.
///
/// Copy takes the row the menu was opened on, selected or not, the way
/// every item of a row's context menu acts on that row; Paste puts the
/// copied layer on top of the shot. Both are disabled rather than hidden
/// when they would do nothing. Each shows the Edit menu's key beside it —
/// shown only: a context menu's key equivalents are live just while it is
/// open, so ⌘C in a text field is still the text field's.
struct LayerPasteboardMenuItems: View {
    /// The engine model the items copy and paste through.
    @Bindable var model: EngineModel

    /// The bottom-to-top index of the row the menu was opened on, or nil
    /// for the empty shot's list, where there is nothing to copy.
    let index: Int?

    /// The two items.
    var body: some View {
        Button {
            guard let index else { return }
            model.copyLayer(at: index, reporting: "layerCopy.menu")
        } label: {
            Text("Copy Layer", comment: "Layer context menu item copying the layer to the pasteboard")
        }
        .keyboardShortcut("c", modifiers: .command)
        .disabled(index == nil)

        Button {
            Task { await model.pasteLayer(reporting: "layerPaste.menu") }
        } label: {
            Text(
                "Paste Layer",
                comment: "Layer context menu item and undo action name: the copied layer is pasted into the shot")
        }
        .keyboardShortcut("v", modifiers: .command)
        .disabled(!model.canPasteLayer())
    }
}

/// The **Layer** menu: ``LayerMenuItems`` over the selected layer of the
/// shot the editor follows, then **Save Snapshot of Layer** — the layer
/// monitor's context-menu command in the menu bar, which works with the
/// monitor closed (ARCHITECTURE.md, "Snapshots"). A menu of its own, after Shots, because the
/// arrange keys need a home that is always there — a shortcut on a control
/// that is scrolled away is a shortcut that does not work (the reasoning
/// under ``ShotCommands``) — and because the menu bar is where a Mac user
/// looks for "which key is Bring to Front".
struct LayerCommands: Commands {
    /// The engine model whose selection the items act on.
    let model: EngineModel

    /// The menu.
    var body: some Commands {
        CommandMenu(Text("Layer", comment: "Title of the Layer menu, arranging the selected layer")) {
            LayerMenuItems(model: model, surface: .menuBar, index: model.selectedLayer?.index)

            Divider()

            Button {
                model.eventBus.tap("snapshotLayer.menuItem", domain: .composition)
                Task { await model.saveSnapshot(.layer) }
            } label: {
                Text(
                    "Save Snapshot of Layer",
                    comment: "Layer menu item saving the selected layer, after its effects, as an image file")
            }
            .disabled(model.selectedLayer == nil)
        }
    }
}
