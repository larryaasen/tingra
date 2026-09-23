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

    /// A window record.
    private func window(_ id: String, plugIn: PlugInID? = nil) -> RegisteredWindow {
        RegisteredWindow(
            plugIn: plugIn ?? notes, plugInName: "Notes",
            descriptor: WindowDescriptor(id: PaneID(rawValue: id), title: "T", sceneID: "w"))
    }

    /// A status item record.
    private func statusItem(_ id: String, plugIn: PlugInID? = nil) -> RegisteredStatusItem {
        RegisteredStatusItem(
            plugIn: plugIn ?? notes, plugInName: "Notes",
            descriptor: StatusItemDescriptor(id: StatusItemID(rawValue: id), title: "T", systemImage: "link"))
    }

    @Test("windows register beside panes, share their id space, and name their plug-in as a hosted scene")
    func windowsRegister() throws {
        let registry = PaneRegistry()
        try registry.register(pane("com.moonwink.tingra.notes.pane"))
        try registry.register(window("com.moonwink.tingra.notes.window"))
        #expect(registry.windows.map(\.id.rawValue) == ["com.moonwink.tingra.notes.window"])
        #expect(registry.window(PaneID(rawValue: "com.moonwink.tingra.notes.window"))?.plugIn == notes)
        #expect(registry.window(PaneID(rawValue: "com.moonwink.tingra.notes.pane")) == nil)
        #expect(throws: PlugInRegistryError.duplicatePane(PaneID(rawValue: "com.moonwink.tingra.notes.pane"))) {
            try registry.register(window("com.moonwink.tingra.notes.pane"))
        }
        #expect(registry.plugIn(hosting: PaneID(rawValue: "com.moonwink.tingra.notes.window")) == notes)
        #expect(registry.plugIn(hosting: PaneID(rawValue: "com.moonwink.tingra.notes.pane")) == notes)
        #expect(registry.plugIn(hosting: PaneID(rawValue: "com.example.unknown")) == nil)
        registry.removeAll(for: notes)
        #expect(registry.windows.isEmpty)
    }

    @Test("a status item is a reading only while it has a text, in registration order")
    func statusItemsReport() throws {
        let registry = StatusItemRegistry()
        try registry.register(statusItem("link"))
        try registry.register(statusItem("count"))
        #expect(registry.readings.isEmpty)
        try registry.setText("12", for: StatusItemID(rawValue: "count"), plugIn: notes)
        try registry.setText("Connected", for: StatusItemID(rawValue: "link"), plugIn: notes)
        #expect(registry.readings.map(\.text) == ["Connected", "12"])
        try registry.setText("", for: StatusItemID(rawValue: "link"), plugIn: notes)
        #expect(registry.readings.map(\.text) == ["12"])
        try registry.setText(nil, for: StatusItemID(rawValue: "count"), plugIn: notes)
        #expect(registry.readings.isEmpty)
    }

    @Test("a repeated status item id within a plug-in throws, and a text for an undeclared item throws")
    func statusItemErrors() throws {
        let registry = StatusItemRegistry()
        let tally = PlugInID(rawValue: "com.example.tally")
        try registry.register(statusItem("link"))
        try registry.register(statusItem("link", plugIn: tally))
        #expect(throws: PlugInRegistryError.duplicateStatusItem(notes, StatusItemID(rawValue: "link"))) {
            try registry.register(statusItem("link"))
        }
        #expect(throws: PlugInRegistryError.unknownStatusItem(notes, StatusItemID(rawValue: "missing"))) {
            try registry.setText("x", for: StatusItemID(rawValue: "missing"), plugIn: notes)
        }
    }

    @Test("a long text is cut to the bar's limit")
    func statusTextIsCut() throws {
        let registry = StatusItemRegistry()
        try registry.register(statusItem("link"))
        try registry.setText(String(repeating: "x", count: 200), for: StatusItemID(rawValue: "link"), plugIn: notes)
        #expect(registry.readings.first?.text.count == StatusItemRegistry.maximumTextLength)
    }

    @Test("clearing a plug-in's texts keeps its items and the other plug-in's readings; removing drops both")
    func statusItemsClearAndRemove() throws {
        let registry = StatusItemRegistry()
        let tally = PlugInID(rawValue: "com.example.tally")
        try registry.register(statusItem("link"))
        try registry.register(statusItem("link", plugIn: tally))
        try registry.setText("A", for: StatusItemID(rawValue: "link"), plugIn: notes)
        try registry.setText("B", for: StatusItemID(rawValue: "link"), plugIn: tally)
        registry.clearTexts(for: notes)
        #expect(registry.readings.map(\.text) == ["B"])
        #expect(registry.items.count == 2)
        try registry.setText("A again", for: StatusItemID(rawValue: "link"), plugIn: notes)
        registry.removeAll(for: notes)
        #expect(registry.items.map(\.plugIn) == [tally])
        #expect(registry.readings.map(\.text) == ["B"])
    }
}
