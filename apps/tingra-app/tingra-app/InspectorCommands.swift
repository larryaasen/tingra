//
//  InspectorCommands.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The View menu's **Show Inspector** / **Hide Inspector** item, ⌥⌘I,
/// beside the sidebar's (``SidebarVisibilityCommands``): the trailing
/// inspector column holds the selected layer's controls
/// (``LayerInspectorColumn``; ARCHITECTURE.md, "The inspector column and the
/// sidebar's casting pickers"). The title flips, Show to Hide, for the reason
/// the sidebar's does.
struct InspectorCommands: Commands {
    /// The engine model the item reports its `tap` to.
    let model: EngineModel

    /// Whether the inspector column is shown — the window's state, owned by
    /// the app scene like the sidebar's visibility.
    @Binding var isPresented: Bool

    /// The item.
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button {
                model.eventBus.tap(
                    "inspector.menuItem",
                    domain: .platform,
                    params: ["visible": .bool(!isPresented)]
                )
                isPresented.toggle()
            } label: {
                Label {
                    InspectorButton.title(isPresented: isPresented)
                } icon: {
                    Image(systemName: InspectorButton.symbol)
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

/// The toolbar's inspector toggle, the trailing-most item after the settings
/// gear — where Xcode and Keynote put theirs — flipping the same state the
/// View menu's item does, under its own `inspector.button` tap.
struct InspectorButton: View {
    /// The engine model the button reports its `tap` to.
    let model: EngineModel

    /// Whether the inspector column is shown.
    @Binding var isPresented: Bool

    /// The symbol both the button and the menu item wear.
    static let symbol = "sidebar.trailing"

    /// The title both wear, flipped by the current state.
    ///
    /// - Parameter isPresented: Whether the column is shown now.
    /// - Returns: Hide Inspector while shown, Show Inspector while hidden.
    static func title(isPresented: Bool) -> Text {
        isPresented
            ? Text("Hide Inspector", comment: "View menu item and toolbar tooltip that hides the inspector column")
            : Text("Show Inspector", comment: "View menu item and toolbar tooltip that shows the inspector column")
    }

    /// The button.
    var body: some View {
        Button {
            model.eventBus.tap(
                "inspector.button",
                domain: .platform,
                params: ["visible": .bool(!isPresented)]
            )
            isPresented.toggle()
        } label: {
            Label {
                Self.title(isPresented: isPresented)
            } icon: {
                Image(systemName: Self.symbol)
            }
        }
        .help(Self.title(isPresented: isPresented))
    }
}
