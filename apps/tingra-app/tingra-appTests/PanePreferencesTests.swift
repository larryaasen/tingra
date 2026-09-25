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

    @Test("a pane never seen is not closed")
    func freshPaneIsNotClosed() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!preferences.isClosed(pane))
    }

    @Test("a closed pane persists under sidebar.<pane>.closed, apart from its expansion")
    func closePersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        preferences.setClosed(true, for: pane)
        #expect(PanePreferences(defaults: defaults).isClosed(pane))
        #expect(defaults.object(forKey: "sidebar.com.moonwink.tingra.notes.pane.closed") as? Bool == true)
        #expect(preferences.isExpanded(pane))
        preferences.setClosed(false, for: pane)
        #expect(!preferences.isClosed(pane))
    }

    @Test("a pane brought back from closed arrives expanded, and closing leaves its expansion alone")
    func hostReopensExpanded() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let host = AppPlugInHost(preferences: preferences)
        host.setExpanded(false, for: pane)
        host.setClosed(true, for: pane)
        #expect(host.isClosed(pane))
        #expect(!host.isExpanded(pane))
        host.setClosed(false, for: pane)
        #expect(!host.isClosed(pane))
        #expect(host.isExpanded(pane))
        #expect(!preferences.isClosed(pane))
        #expect(preferences.isExpanded(pane))
    }

    @Test("the Settings window's Plug-ins section is open until collapsed, persisting under its own key")
    func settingsSectionPersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(preferences.isSettingsSectionExpanded)
        preferences.setSettingsSectionExpanded(false)
        #expect(!PanePreferences(defaults: defaults).isSettingsSectionExpanded)
        #expect(defaults.object(forKey: "settings.plugIns.expanded") as? Bool == false)
        preferences.setSettingsSectionExpanded(true)
        #expect(preferences.isSettingsSectionExpanded)
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
