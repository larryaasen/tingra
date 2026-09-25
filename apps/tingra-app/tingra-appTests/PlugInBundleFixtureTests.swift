//
//  PlugInBundleFixtureTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// A class in the test bundle, so `Bundle(for:)` finds the bundle that
/// carries the fixture in its `Contents/PlugIns`.
private final class TestBundleLocator {}

/// The real proof of the host tier's bundle loader (PLUGINS.md, Decision 27):
/// `FixturePlugIn.tingraplugin`, built by its own target apart from the app
/// and linking the kit without embedding it, loads through the production
/// ``PlugInBundleLoader`` — real Info.plist, real signature check, real
/// `dlopen` — and what it registers lands in the host's own registry.
@Suite("Plug-in bundle fixture")
struct PlugInBundleFixtureTests {
    /// The fixture's id, which its Info.plist and principal class share.
    private let fixtureID = "com.moonwink.tingra.fixture"

    /// The fixture as the test bundle carries it.
    private func builtFixture() throws -> URL {
        let plugIns = try #require(Bundle(for: TestBundleLocator.self).builtInPlugInsURL)
        let fixture = plugIns.appending(path: "FixturePlugIn.tingraplugin", directoryHint: .isDirectory)
        try #require(FileManager.default.fileExists(atPath: fixture.path(percentEncoded: false)))
        return fixture
    }

    /// Copies the fixture into a fresh plug-in folder and runs `codesign`
    /// over the copy with the given arguments, so the test does not depend
    /// on how the build signed it (CI builds with signing off).
    ///
    /// - Parameter codesignArguments: The arguments before the bundle's path.
    /// - Returns: The plug-in folder holding the copy.
    private func stagedFolder(codesignArguments: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "PlugInBundleFixtureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: "FixturePlugIn.tingraplugin", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: try builtFixture(), to: copy)

        let codesign = Process()
        codesign.executableURL = URL(filePath: "/usr/bin/codesign")
        codesign.arguments = codesignArguments + [copy.path(percentEncoded: false)]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0)
        return folder
    }

    /// A context over fresh registries and the given bus.
    private func context(eventBus: EventBus, inputs: InputRegistry) -> PlugInContext {
        PlugInContext(
            eventBus: eventBus, clock: HostClock(), inputs: inputs, outputs: OutputRegistry(),
            effects: EffectRegistry(), tools: ToolRegistry())
    }

    @Test("the fixture loads through the production loader and its input lands in the host's registry")
    func fixtureLoadsAndActivates() async throws {
        let folder = try stagedFolder(codesignArguments: ["--sign", "-", "--force"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let eventBus = EventBus()
        let events = eventBus.events()
        let inputs = InputRegistry()

        let activated = await PlugInLoader().activate(
            [], thenBundlesFrom: PlugInBundleLoader(folders: [folder]),
            in: context(eventBus: eventBus, inputs: inputs))
        eventBus.shutdown()
        var received: [EventBusEvent] = []
        for await event in events {
            received.append(event)
        }

        #expect(activated.map(\.id.rawValue) == [fixtureID])
        #expect(await inputs.allInputs.map(\.id.rawValue) == ["com.moonwink.tingra.fixture.input"])
        #expect(received.filter { $0.name == "plugin.bundle" }.isEmpty)
        let activation = received.first { $0.name == "plugin.activated" }
        #expect(activation?.params?["id"] == .string(fixtureID))
        #expect(activation?.params?["source"] == .string("bundle"))
        #expect(received.contains { $0.name == "fixture.activated" })
    }

    @Test("the kit version the fixture declares is one this host loads")
    func fixtureDeclaresALoadableKitVersion() throws {
        let info = try #require(FoundationPlugInBundleOpener().info(ofBundleAt: try builtFixture()))
        let version = try #require(info.kitVersion.flatMap(PlugInKitVersion.init))

        #expect(info.id == fixtureID)
        #expect(PlugInBundleLoader.canLoad(builtAgainst: version, in: .current))
    }

    @Test("an unsigned copy of the fixture is refused before any of its code loads")
    func unsignedFixtureIsRefused() throws {
        let folder = try stagedFolder(codesignArguments: ["--remove-signature"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let scan = PlugInBundleLoader(folders: [folder]).load(skipping: [], reportingTo: EventBus())

        #expect(scan.loaded.isEmpty)
        #expect(scan.problems.map(\.reason) == [.unsigned])
    }
}
