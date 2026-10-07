//
//  WindowCloseCommands.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

extension FocusedValues {
    /// How to close the window that has the keyboard, when it is one that
    /// File ▸ Close may close — every window but the main one
    /// (``WindowCloseCommands``). Nil while the main window is key.
    @Entry var windowClose: DismissAction?
}

extension View {
    /// Marks this view's window as one File ▸ Close (⌘W) closes.
    ///
    /// Applied at the root of each auxiliary window — Settings, Multiview,
    /// the log, a plug-in's window — and never to the main window, which is
    /// the show and has no Close (``ProjectCommands``).
    ///
    /// - Returns: The view, publishing its window's dismiss action to the
    ///   menu while its window is key.
    func closesWithCloseCommand() -> some View {
        modifier(WindowCloseModifier())
    }
}

/// Publishes a window's own dismiss action as the scene's
/// ``SwiftUICore/FocusedValues/windowClose``. A modifier rather than a line
/// at each call site because `dismiss` has to be read from *inside* the
/// window it closes.
private struct WindowCloseModifier: ViewModifier {
    /// Closes the window this modifier's content is in.
    @Environment(\.dismiss) private var dismiss

    /// The content, publishing the dismiss action for its scene.
    func body(content: Content) -> some View {
        content.focusedSceneValue(\.windowClose, dismiss)
    }
}

/// File ▸ Close, under ⌘W, for the windows beside the main one.
///
/// ``ProjectCommands`` replaces the File menu's save group, and SwiftUI's
/// own Close item lives in that group, so it went with it — deliberately for
/// the main window, which is the show, but it took ⌘W away from Settings,
/// Multiview, the log, and plug-in windows too (Larry, 2026-10-06: "make
/// command-W close it just like normal Close works"). This puts Close back
/// for exactly those: the item is disabled while the main window is key.
struct WindowCloseCommands: Commands {
    /// The engine model — here for its event bus, so the item reports its
    /// `tap`.
    let model: EngineModel

    /// How to close the key window, or nil when it is the main window.
    @FocusedValue(\.windowClose) private var windowClose

    /// The item, after the project's own File items.
    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button {
                model.eventBus.tap("windowClose.menuItem", domain: .platform)
                windowClose?()
            } label: {
                Text("Close", comment: "File menu item closing the frontmost window, when it is not the main window")
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(windowClose == nil)
        }
    }
}
