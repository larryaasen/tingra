//
//  PanePreferences.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI
import TingraAppPlugInKit

/// Which plug-in panes are open in the trailing sidebar: machine-local
/// preferences keyed by pane id, following ``SidebarPreferences`` exactly —
/// an open pane is the *absence* of a value, so a fresh install shows every
/// pane, and a pane id never seen has no stale state to inherit.
struct PanePreferences {
    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// Creates the preferences.
    ///
    /// - Parameter defaults: The defaults database (the standard one by
    ///   default; a throwaway suite under test).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The defaults key a pane's expansion persists under.
    static func expansionKey(for pane: PaneID) -> String { "sidebar.\(pane.rawValue).expanded" }

    /// Whether the pane is open; open unless it was collapsed.
    func isExpanded(_ pane: PaneID) -> Bool {
        defaults.object(forKey: Self.expansionKey(for: pane)) as? Bool ?? true
    }

    /// Records whether the pane is open.
    func setExpanded(_ isExpanded: Bool, for pane: PaneID) {
        defaults.set(isExpanded, forKey: Self.expansionKey(for: pane))
    }
}

/// Turns a manifest's shortcut into the SwiftUI shortcut a menu item
/// carries: one character and the named modifiers. A descriptor with no
/// single character yields nil, so a malformed manifest loses its shortcut
/// rather than its menu item.
enum PlugInShortcut {
    /// The keyboard shortcut for a descriptor, or nil when its key is not
    /// one character.
    static func keyboardShortcut(_ descriptor: ShortcutDescriptor) -> KeyboardShortcut? {
        guard descriptor.key.count == 1, let character = descriptor.key.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers(descriptor.modifiers))
    }

    /// The event modifiers for the named modifiers.
    static func modifiers(_ named: [ShortcutDescriptor.Modifier]) -> EventModifiers {
        named.reduce(into: EventModifiers()) { modifiers, modifier in
            switch modifier {
            case .command: modifiers.insert(.command)
            case .option: modifiers.insert(.option)
            case .shift: modifiers.insert(.shift)
            case .control: modifiers.insert(.control)
            }
        }
    }
}
