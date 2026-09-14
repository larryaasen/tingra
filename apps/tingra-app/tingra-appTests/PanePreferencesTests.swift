//
//  PanePreferencesTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI
import Testing
import TingraAppPlugInKit

@testable import TingraApp

/// Plug-in pane expansion persistence and the manifest shortcut's
/// conversion to a SwiftUI shortcut.
@Suite("PanePreferences")
struct PanePreferencesTests {
    /// The Notes pane's id.
    private let pane = PaneID(rawValue: "com.moonwink.tingra.notes.pane")

    /// A throwaway defaults suite.
    private func makePreferences() throws -> (PanePreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (PanePreferences(defaults: defaults), defaults, name)
    }

    @Test("a pane never seen is open")
    func freshPaneIsExpanded() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(preferences.isExpanded(pane))
    }

    @Test("a collapsed pane persists under sidebar.<pane>.expanded and is read back")
    func collapsePersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.setExpanded(false, for: pane)
        #expect(!PanePreferences(defaults: defaults).isExpanded(pane))
        #expect(defaults.object(forKey: "sidebar.com.moonwink.tingra.notes.pane.expanded") as? Bool == false)
        preferences.setExpanded(true, for: pane)
        #expect(preferences.isExpanded(pane))
    }

    @Test("a one-character key with modifiers becomes a keyboard shortcut")
    func shortcutConverts() throws {
        let shortcut = try #require(
            PlugInShortcut.keyboardShortcut(ShortcutDescriptor(key: "n", modifiers: [.command, .option])))
        #expect(shortcut.key == KeyEquivalent("n"))
        #expect(shortcut.modifiers == [.command, .option])
        #expect(PlugInShortcut.modifiers([.shift, .control]) == [.shift, .control])
    }

    @Test("a key that is not one character yields no shortcut")
    func malformedKeyYieldsNil() {
        #expect(PlugInShortcut.keyboardShortcut(ShortcutDescriptor(key: "", modifiers: [.command])) == nil)
        #expect(PlugInShortcut.keyboardShortcut(ShortcutDescriptor(key: "np", modifiers: [])) == nil)
    }
}
