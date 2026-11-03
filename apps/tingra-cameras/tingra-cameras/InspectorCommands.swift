//
//  InspectorCommands.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-31.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The View menu's **Show Inspector** / **Hide Inspector** item, ⌥⌘I, the
/// main Tingra app's item for the same column. The state is per window, so
/// the item drives the key window's (the focused scene value ``ContentView``
/// publishes) and is disabled with no window open.
struct InspectorCommands: Commands {
    /// The shared hardware model, for the command's `tap` event.
    let model: HardwareModel

    /// Whether the key window's trailing sidebar is shown, or nil with no
    /// window open.
    @FocusedBinding(\.isInspectorPresented) private var isPresented

    /// The item.
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button {
                guard let isPresented else { return }
                model.recordTap("inspector.menuItem", params: ["visible": .bool(!isPresented)])
                self.isPresented = !isPresented
            } label: {
                Label {
                    InspectorButton.title(isPresented: isPresented ?? false)
                } icon: {
                    Image(systemName: InspectorButton.symbol)
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(isPresented == nil)
        }
    }
}

/// The toolbar's trailing sidebar toggle, flipping the same state the View
/// menu's item does, under its own `inspector.button` tap.
struct InspectorButton: View {
    /// The shared hardware model, for the button's `tap` event.
    @Environment(HardwareModel.self) private var model

    /// Whether the trailing sidebar is shown.
    @Binding var isPresented: Bool

    /// The symbol both the button and the menu item wear.
    static let symbol = "sidebar.trailing"

    /// The title both wear, flipped by the current state.
    ///
    /// - Parameter isPresented: Whether the sidebar is shown now.
    /// - Returns: Hide Inspector while shown, Show Inspector while hidden.
    static func title(isPresented: Bool) -> Text {
        isPresented
            ? Text("Hide Inspector", comment: "View menu item and toolbar tooltip that hides the trailing sidebar")
            : Text("Show Inspector", comment: "View menu item and toolbar tooltip that shows the trailing sidebar")
    }

    /// The button.
    var body: some View {
        Button {
            model.recordTap("inspector.button", params: ["visible": .bool(!isPresented)])
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

extension FocusedValues {
    /// Whether the key window's trailing sidebar is shown, for the View
    /// menu's item.
    @Entry var isInspectorPresented: Binding<Bool>?
}
