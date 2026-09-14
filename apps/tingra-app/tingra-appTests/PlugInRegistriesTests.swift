//
//  PlugInRegistriesTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraAppPlugInKit
import TingraPlugInKit

@testable import TingraApp

/// The app tier's registries: panes, settings panes, and commands by
/// plug-in, with duplicate ids rejected and a plug-in's rows removable.
@Suite("Plug-in registries")
struct PlugInRegistriesTests {
    /// The Notes plug-in's id.
    private let notes = PlugInID(rawValue: "com.moonwink.tingra.notes")

    /// A pane record.
    private func pane(_ id: String, plugIn: PlugInID? = nil) -> RegisteredPane {
        RegisteredPane(
            plugIn: plugIn ?? notes, plugInName: "Notes",
            descriptor: PaneDescriptor(id: PaneID(rawValue: id), title: "T", systemImage: "note.text", sceneID: "p"))
    }

    /// A command record.
    private func command(_ id: String, plugIn: PlugInID? = nil, name: String = "Notes") -> RegisteredCommand {
        RegisteredCommand(
            plugIn: plugIn ?? notes, plugInName: name,
            descriptor: CommandDescriptor(id: CommandID(rawValue: id), title: "T")
        )
    }

    @Test("panes register in order and a repeated id throws")
    func panesRegister() throws {
        let registry = PaneRegistry()
        try registry.register(pane("com.moonwink.tingra.notes.pane"))
        try registry.register(pane("com.moonwink.tingra.notes.other"))
        #expect(
            registry.panes.map(\.id.rawValue) == ["com.moonwink.tingra.notes.pane", "com.moonwink.tingra.notes.other"])
        #expect(throws: PlugInRegistryError.duplicatePane(PaneID(rawValue: "com.moonwink.tingra.notes.pane"))) {
            try registry.register(pane("com.moonwink.tingra.notes.pane"))
        }
        #expect(registry.pane(PaneID(rawValue: "com.moonwink.tingra.notes.other"))?.plugIn == notes)
    }

    @Test("a settings pane and a sidebar pane cannot share an id")
    func settingsPaneIDsAreShared() throws {
        let registry = PaneRegistry()
        try registry.register(pane("com.moonwink.tingra.notes.pane"))
        let settings = RegisteredSettingsPane(
            plugIn: notes,
            descriptor: SettingsPaneDescriptor(
                id: PaneID(rawValue: "com.moonwink.tingra.notes.pane"), title: "T", systemImage: "s", sceneID: "s"))
        #expect(throws: PlugInRegistryError.self) { try registry.register(settings) }
    }

    @Test("removing a plug-in's panes leaves the others")
    func removeAllPanes() throws {
        let registry = PaneRegistry()
        let other = PlugInID(rawValue: "com.example.other")
        try registry.register(pane("com.moonwink.tingra.notes.pane"))
        try registry.register(pane("com.example.other.pane", plugIn: other))
        registry.removeAll(for: notes)
        #expect(registry.panes.map(\.plugIn) == [other])
    }

    @Test("commands group by plug-in in first-registration order")
    func commandsGroup() throws {
        let registry = CommandRegistry()
        let other = PlugInID(rawValue: "com.example.other")
        try registry.register(command("show"))
        try registry.register(command("go", plugIn: other, name: "Other"))
        try registry.register(command("clear"))
        #expect(registry.plugIns.map(\.id) == [notes, other])
        #expect(registry.plugIns.map(\.name) == ["Notes", "Other"])
        #expect(registry.commands(for: notes).map(\.descriptor.id.rawValue) == ["show", "clear"])
    }

    @Test("a repeated command id within a plug-in throws, the same id in another plug-in registers")
    func duplicateCommands() throws {
        let registry = CommandRegistry()
        try registry.register(command("show"))
        #expect(throws: PlugInRegistryError.duplicateCommand(notes, CommandID(rawValue: "show"))) {
            try registry.register(command("show"))
        }
        try registry.register(command("show", plugIn: PlugInID(rawValue: "com.example.other")))
        #expect(registry.commands.count == 2)
    }

    @Test("a command's tap name is the plug-in id, the command id, and menuItem")
    func tapName() {
        #expect(command("show").tapName == "com.moonwink.tingra.notes.show.menuItem")
    }
}
