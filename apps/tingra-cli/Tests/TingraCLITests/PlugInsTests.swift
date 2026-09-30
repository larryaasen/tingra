//
//  PlugInsTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-09-29.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraCLI

/// A temporary folder for an enablement file, removed when the test ends.
private struct StateFolder {
    /// The folder.
    let url = FileManager.default.temporaryDirectory.appending(
        path: "PlugInsTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// The enablement file in it.
    var store: PlugInEnablementStore { PlugInEnablementStore(directory: url) }

    /// Deletes the folder and everything in it.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// An installed bundle's id.
private let alpha = PlugInID(rawValue: "com.example.alpha")

/// A compiled-in plug-in's id.
private let builtIn = PlugInID(rawValue: "com.moonwink.tingra.generators")

@Suite("tingra-cli plug-ins")
struct PlugInsTests {
    /// A switch over one installed bundle, `alpha`, and one compiled-in
    /// plug-in, keeping its file in `folder`.
    private func plugInSwitch(_ folder: StateFolder, declared: Set<PlugInID> = [alpha]) -> PlugInSwitch {
        PlugInSwitch(
            compiledInIDs: [builtIn], declaredIDs: declared, folders: ["~/Plug-ins", "/Library/Plug-ins"],
            store: folder.store)
    }

    @Test("the listing is the default subcommand, and takes --json")
    func listIsTheDefault() throws {
        let parsed = try PlugIns.parseAsRoot(["--json"])

        #expect((parsed as? PlugIns.List)?.json == true)
    }

    @Test("enable and disable each take the id as an argument")
    func enableAndDisableTakeAnID() throws {
        #expect(
            (try PlugIns.parseAsRoot(["enable", "com.example.alpha"]) as? PlugIns.Enable)?.id == "com.example.alpha")
        #expect(
            (try PlugIns.parseAsRoot(["disable", "com.example.alpha"]) as? PlugIns.Disable)?.id == "com.example.alpha")
    }

    @Test("the serve engine's compiled-in plug-ins are the five the daemon runs")
    func compiledInPlugIns() {
        let ids = DaemonEngine(eventBus: EventBus()).compiledInPlugIns.map(\.id.rawValue)

        #expect(ids.count == 5)
        #expect(ids.contains("com.moonwink.tingra.control"))
        #expect(Set(ids).count == ids.count)
    }

    @Test("disable turns an installed bundle off in the file, and enable turns it back on")
    func disableThenEnable() throws {
        let folder = StateFolder()
        defer { folder.remove() }
        let plugInSwitch = plugInSwitch(folder)

        #expect(try plugInSwitch.set(alpha, on: false) == .changed)
        #expect(try folder.store.read().isDisabled(alpha))
        #expect(try plugInSwitch.set(alpha, on: true) == .changed)
        #expect(try !folder.store.read().isDisabled(alpha))
    }

    @Test("enable on a plug-in already on, or disable on one already off, changes nothing")
    func repeatedSwitchIsUnchanged() throws {
        let folder = StateFolder()
        defer { folder.remove() }
        let plugInSwitch = plugInSwitch(folder)

        #expect(try plugInSwitch.set(alpha, on: true) == .unchanged)
        #expect(!FileManager.default.fileExists(atPath: folder.store.fileURL.path(percentEncoded: false)))
        _ = try plugInSwitch.set(alpha, on: false)
        #expect(try plugInSwitch.set(alpha, on: false) == .unchanged)
    }

    @Test("enable clears a crash record, turning the bundle back on")
    func enableClearsACrash() throws {
        let folder = StateFolder()
        defer { folder.remove() }
        try folder.store.update {
            $0.recordCrash(
                CrashedPlugInBundle(id: alpha, cdHash: "abc", path: "~/A", frontEnd: "Tingra", date: .now))
        }

        #expect(try plugInSwitch(folder).set(alpha, on: true) == .changed)
        #expect(try folder.store.read().crash(of: alpha) == nil)
    }

    @Test("a compiled-in id is refused both ways, as a usage error")
    func compiledInIsRefused() throws {
        let folder = StateFolder()
        defer { folder.remove() }

        for on in [true, false] {
            #expect(throws: PlugInSwitch.Refusal.compiledIn(builtIn)) {
                try plugInSwitch(folder).set(builtIn, on: on)
            }
        }
        #expect(PlugInSwitch.Refusal.compiledIn(builtIn).exitCode == 64)
        #expect(PlugInSwitch.Refusal.compiledIn(builtIn).description.contains("always on"))
    }

    @Test("an id no bundle declares is refused, naming the folders searched")
    func unknownIDIsRefused() throws {
        let folder = StateFolder()
        defer { folder.remove() }
        let unknown = PlugInID(rawValue: "com.example.nothing")
        let refusal = PlugInSwitch.Refusal.unknownID(unknown, folders: ["~/Plug-ins", "/Library/Plug-ins"])

        #expect(throws: refusal) { try plugInSwitch(folder).set(unknown, on: false) }
        #expect(throws: refusal) { try plugInSwitch(folder).set(unknown, on: true) }
        #expect(refusal.exitCode == 64)
        #expect(refusal.description.contains("~/Plug-ins or /Library/Plug-ins"))
    }

    @Test("enable clears an id the file records though its bundle has been removed")
    func enableClearsARemovedBundle() throws {
        let folder = StateFolder()
        defer { folder.remove() }
        _ = try plugInSwitch(folder).set(alpha, on: false)

        #expect(try plugInSwitch(folder, declared: []).set(alpha, on: true) == .changed)
        #expect(throws: PlugInSwitch.Refusal.self) { try plugInSwitch(folder, declared: []).set(alpha, on: false) }
    }

    @Test("an unreadable enablement file is reported, left untouched, and exits as an internal error")
    func unreadableFileIsReported() throws {
        let folder = StateFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.store.fileURL)

        #expect {
            try plugInSwitch(folder).set(alpha, on: false)
        } throws: { error in
            guard case .store(.unreadable) = error as? PlugInSwitch.Refusal else { return false }
            return (error as? PlugInSwitch.Refusal)?.exitCode == 70
        }
        #expect(try Data(contentsOf: folder.store.fileURL) == Data("not json".utf8))
    }

    @Test("the confirmation says what changed, or that nothing did")
    func confirmations() {
        #expect(
            PlugInSwitch.confirmation(for: .changed, id: alpha, on: false).hasPrefix("Turned 'com.example.alpha' off."))
        #expect(PlugInSwitch.confirmation(for: .unchanged, id: alpha, on: true) == "'com.example.alpha' is already on.")
    }

    @Test("the table lists built-in plug-ins, then installed bundles with their path and what went wrong")
    func table() {
        let report = PlugInLoadReport(
            kitVersion: "0.1.0", safeMode: false, folders: ["~/Plug-ins"],
            plugIns: [
                .init(
                    id: "com.example.core", name: "Core", version: nil, source: .compiledIn, path: nil, state: .active,
                    reason: nil, message: nil, warnings: []),
                .init(
                    id: "com.example.alpha", name: "Alpha", version: "1.0", source: .bundle, path: "~/Plug-ins/A",
                    state: .active, reason: nil, message: nil, warnings: ["embeds a kit"]),
                .init(
                    id: nil, name: "Broken", version: nil, source: .bundle, path: "~/Plug-ins/B", state: .refused,
                    reason: "loadFailed", message: "no Info.plist", warnings: []),
            ])

        #expect(
            report.table == """
                PLUG-IN KIT 0.1.0
                BUILT IN
                  active   Core  (id: com.example.core)
                INSTALLED
                  active   Alpha 1.0  (id: com.example.alpha)
                           ~/Plug-ins/A
                           warning: embeds a kit
                  refused  Broken     (id: none declared)
                           ~/Plug-ins/B
                           loadFailed: no Info.plist
                """)
    }

    @Test("the table names safe mode, and where bundles go when none is installed")
    func tableInSafeModeWithNothingInstalled() {
        let report = PlugInLoadReport(kitVersion: "0.1.0", safeMode: true, folders: ["~/A", "/B"], plugIns: [])

        #expect(
            report.table == """
                PLUG-IN KIT 0.1.0 — SAFE MODE: no plug-in bundles were loaded
                BUILT IN
                  (none)
                INSTALLED
                  (none; plug-in bundles are installed in ~/A or /B)
                """)
    }
}
