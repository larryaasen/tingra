//
//  ManifestTests.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraAppPlugInKit

/// The manifest an app-tier plug-in declares in its Info.plist: decoding
/// from the property list dictionary, the optional lists, the id rules.
@Suite("Plug-in manifest")
struct ManifestTests {
    /// A full Info.plist dictionary as the extension's bundle would carry it.
    private func infoDictionary(manifest: [String: Any]) -> [String: Any] {
        [
            "CFBundleIdentifier": "com.moonwink.tingra.app.notes",
            "EXAppExtensionAttributes": [
                "EXExtensionPointIdentifier": "com.moonwink.tingra.app.plug-in",
                "TingraPlugIn": manifest,
            ] as [String: Any],
        ]
    }

    /// The Notes manifest.
    private var notes: [String: Any] {
        [
            "id": "com.moonwink.tingra.notes",
            "name": "Notes",
            "panes": [
                [
                    "id": "com.moonwink.tingra.notes.pane", "title": "Notes", "systemImage": "note.text",
                    "preferredSidebar": "trailing", "sceneID": "pane",
                ]
            ],
            "commands": [
                [
                    "id": "show", "title": "Show Notes", "shortcut": ["key": "n", "modifiers": ["command", "option"]],
                    "showsPane": "com.moonwink.tingra.notes.pane",
                ]
            ],
            "settingsPanes": [
                [
                    "id": "com.moonwink.tingra.notes.settings", "title": "Notes", "systemImage": "note.text",
                    "sceneID": "settings",
                ]
            ],
            "windows": [["id": "com.moonwink.tingra.notes.window", "title": "Notes", "sceneID": "window"]],
            "statusItems": [["id": "words", "title": "Word Count", "systemImage": "textformat.123"]],
            "activation": ["stream.started", "device.connected:kind=camera"],
        ]
    }

    @Test("a full manifest decodes every descriptor")
    func decodesFullManifest() throws {
        let manifest = try PlugInManifest(infoDictionary: infoDictionary(manifest: notes))
        #expect(manifest.id == PlugInID(rawValue: "com.moonwink.tingra.notes"))
        #expect(manifest.name == "Notes")
        #expect(manifest.panes.count == 1)
        #expect(manifest.panes.first?.id == PaneID(rawValue: "com.moonwink.tingra.notes.pane"))
        #expect(manifest.panes.first?.preferredSidebar == .trailing)
        #expect(manifest.panes.first?.sceneID == "pane")
        let command = try #require(manifest.commands.first)
        #expect(command.id == CommandID(rawValue: "show"))
        #expect(command.shortcut == ShortcutDescriptor(key: "n", modifiers: [.command, .option]))
        #expect(command.placement == .plugInMenu)
        #expect(command.showsPane == PaneID(rawValue: "com.moonwink.tingra.notes.pane"))
        #expect(manifest.settingsPanes.first?.sceneID == "settings")
        #expect(
            manifest.windows == [
                WindowDescriptor(
                    id: PaneID(rawValue: "com.moonwink.tingra.notes.window"), title: "Notes", sceneID: "window")
            ])
        #expect(
            manifest.statusItems == [
                StatusItemDescriptor(
                    id: StatusItemID(rawValue: "words"), title: "Word Count", systemImage: "textformat.123")
            ])
        #expect(
            manifest.activation == [
                ActivationCondition(event: "stream.started"),
                ActivationCondition(
                    event: "device.connected", qualifier: ActivationCondition.Qualifier(key: "kind", value: "camera")),
            ])
    }

    @Test("the lists and the placement may be omitted")
    func decodesMinimalManifest() throws {
        let manifest = try PlugInManifest(
            infoDictionary: infoDictionary(manifest: [
                "id": "com.example.minimal", "name": "Minimal", "commands": [["id": "go", "title": "Go"]],
            ]))
        #expect(manifest.panes.isEmpty)
        #expect(manifest.settingsPanes.isEmpty)
        #expect(manifest.windows.isEmpty)
        #expect(manifest.statusItems.isEmpty)
        #expect(manifest.activation.isEmpty)
        let withPane = try PlugInManifest(
            infoDictionary: infoDictionary(manifest: [
                "id": "com.example.minimal", "name": "Minimal",
                "panes": [["id": "com.example.minimal.pane", "title": "P", "systemImage": "s", "sceneID": "p"]],
            ]))
        #expect(withPane.panes.first?.preferredSidebar == .trailing)
        #expect(manifest.commands.first?.shortcut == nil)
        #expect(manifest.commands.first?.placement == .plugInMenu)
        #expect(manifest.commands.first?.showsPane == nil)
        #expect(manifest.commands.first?.showsWindow == nil)
    }

    @Test("a command may name the window it opens")
    func decodesShowsWindow() throws {
        var manifest = notes
        manifest["commands"] = [["id": "open", "title": "Open", "showsWindow": "com.moonwink.tingra.notes.window"]]
        let decoded = try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
        #expect(decoded.commands.first?.showsWindow == PaneID(rawValue: "com.moonwink.tingra.notes.window"))
        #expect(decoded.commands.first?.showsPane == nil)
    }

    @Test("a window id outside the plug-in's namespace throws")
    func throwsForWindowOutsidePlugIn() {
        var manifest = notes
        manifest["windows"] = [["id": "com.other.window", "title": "T", "sceneID": "w"]]
        #expect(
            throws: PlugInManifestError.paneOutsidePlugIn(
                PaneID(rawValue: "com.other.window"), plugIn: PlugInID(rawValue: "com.moonwink.tingra.notes"))
        ) {
            try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
        }
    }

    @Test("a window sharing a pane's id throws")
    func throwsForWindowSharingPaneID() {
        var manifest = notes
        manifest["windows"] = [["id": "com.moonwink.tingra.notes.pane", "title": "T", "sceneID": "w"]]
        #expect(throws: PlugInManifestError.duplicatePane(PaneID(rawValue: "com.moonwink.tingra.notes.pane"))) {
            try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
        }
    }

    @Test("a repeated status item id throws")
    func throwsForDuplicateStatusItem() {
        var manifest = notes
        manifest["statusItems"] = [
            ["id": "words", "title": "A", "systemImage": "a"], ["id": "words", "title": "B", "systemImage": "b"],
        ]
        #expect(throws: PlugInManifestError.duplicateStatusItem(StatusItemID(rawValue: "words"))) {
            try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
        }
    }

    @Test("a status item without a symbol throws as malformed")
    func throwsForStatusItemWithoutSymbol() {
        var manifest = notes
        manifest["statusItems"] = [["id": "words", "title": "A"]]
        #expect(throws: PlugInManifestError.self) {
            try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
        }
    }

    @Test("a missing attributes dictionary throws naming the key")
    func throwsWithoutAttributes() {
        #expect(throws: PlugInManifestError.missingKey("EXAppExtensionAttributes")) {
            try PlugInManifest(infoDictionary: ["CFBundleIdentifier": "x"])
        }
    }

    @Test("a missing manifest dictionary throws naming the key path")
    func throwsWithoutManifest() {
        #expect(throws: PlugInManifestError.missingKey("EXAppExtensionAttributes.TingraPlugIn")) {
            try PlugInManifest(infoDictionary: [
                "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "p"] as [String: Any]
            ])
        }
    }

    @Test("a manifest without a name throws as malformed")
    func throwsWhenMalformed() {
        #expect(throws: PlugInManifestError.self) {
            try PlugInManifest(infoDictionary: infoDictionary(manifest: ["id": "com.example.x"]))
        }
    }

    @Test("a pane id outside the plug-in's namespace throws")
    func throwsForPaneOutsidePlugIn() {
        var manifest = notes
        manifest["panes"] = [["id": "com.other.pane", "title": "T", "systemImage": "s", "sceneID": "p"]]
        #expect(
            throws: PlugInManifestError.paneOutsidePlugIn(
                PaneID(rawValue: "com.other.pane"), plugIn: PlugInID(rawValue: "com.moonwink.tingra.notes"))
        ) {
            try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
        }
    }

    @Test("a repeated command id throws")
    func throwsForDuplicateCommand() {
        var manifest = notes
        manifest["commands"] = [["id": "show", "title": "A"], ["id": "show", "title": "B"]]
        #expect(throws: PlugInManifestError.duplicateCommand(CommandID(rawValue: "show"))) {
            try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
        }
    }

    @Test("a repeated activation condition throws")
    func throwsForDuplicateActivation() {
        var manifest = notes
        manifest["activation"] = ["stream.started", "stream.started"]
        #expect(throws: PlugInManifestError.duplicateActivation(ActivationCondition(event: "stream.started"))) {
            try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
        }
    }

    @Test("a malformed activation condition throws as malformed, naming it")
    func throwsForMalformedActivation() {
        var manifest = notes
        manifest["activation"] = ["device.connected:camera"]
        do {
            _ = try PlugInManifest(infoDictionary: infoDictionary(manifest: manifest))
            Issue.record("A malformed condition decoded.")
        } catch let error as PlugInManifestError {
            guard case .malformed(let detail) = error else {
                Issue.record("Unexpected error \(error).")
                return
            }
            #expect(detail.contains("device.connected:camera"))
        } catch {
            Issue.record("Unexpected error \(error).")
        }
    }

    @Test("a manifest round-trips through Codable")
    func roundTrips() throws {
        let original = try PlugInManifest(infoDictionary: infoDictionary(manifest: notes))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlugInManifest.self, from: data)
        #expect(decoded == original)
        let other = PlugInManifest(id: PlugInID(rawValue: "com.example.other"), name: "Other")
        #expect(decoded != other)
    }
}
