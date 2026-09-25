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

    /// The defaults key a pane's closed state persists under.
    static func closedKey(for pane: PaneID) -> String { "sidebar.\(pane.rawValue).closed" }

    /// Whether the pane was closed out of its sidebar; shown unless it was.
    /// Separate from expansion: a collapsed pane keeps its header, a closed
    /// one is gone until the View menu brings it back.
    func isClosed(_ pane: PaneID) -> Bool {
        defaults.bool(forKey: Self.closedKey(for: pane))
    }

    /// Records whether the pane is closed.
    func setClosed(_ isClosed: Bool, for pane: PaneID) {
        defaults.set(isClosed, forKey: Self.closedKey(for: pane))
    }

    /// Records whether the pane is open.
    func setExpanded(_ isExpanded: Bool, for pane: PaneID) {
        defaults.set(isExpanded, forKey: Self.expansionKey(for: pane))
    }

    /// The defaults key the Settings window's Plug-ins section persists
    /// under — the collapsible heading over the plug-ins' settings panes.
    static let settingsSectionExpansionKey = "settings.plugIns.expanded"

    /// Whether the Settings window's Plug-ins section is open; open unless
    /// it was collapsed.
    var isSettingsSectionExpanded: Bool {
        defaults.object(forKey: Self.settingsSectionExpansionKey) as? Bool ?? true
    }

    /// Records whether the Settings window's Plug-ins section is open.
    func setSettingsSectionExpanded(_ isExpanded: Bool) {
        defaults.set(isExpanded, forKey: Self.settingsSectionExpansionKey)
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
