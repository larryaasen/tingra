//
//  SafeModeLaunchTests.swift
//  TingraAppTests
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost

@testable import TingraApp

/// Drains a bus after shutting it down.
private func drain(_ eventBus: EventBus, _ events: AsyncStream<EventBusEvent>) async -> [EventBusEvent] {
    eventBus.shutdown()
    var received: [EventBusEvent] = []
    for await event in events {
        received.append(event)
    }
    return received
}

@Suite("SafeModeLaunch")
struct SafeModeLaunchTests {
    @Test("Shift held at launch is safe mode, and no question is asked even after an unclean exit")
    func shiftWins() {
        var asked = false

        let launch = SafeModeLaunch.decide(shiftHeld: true, lastRunBundles: ["A.tingraplugin"]) { _ in
            asked = true
            return .normally
        }

        #expect(launch == SafeModeLaunch(trigger: .shiftKey))
        #expect(!asked)
    }

    @Test("a clean last run is a normal launch, and no question is asked")
    func cleanLastRunIsNormal() {
        var asked = false

        let launch = SafeModeLaunch.decide(shiftHeld: false, lastRunBundles: nil) { _ in
            asked = true
            return .safeMode
        }

        #expect(launch == .normal)
        #expect(!asked)
    }

    @Test("after an unclean exit with bundles loaded, the operator is asked, naming them")
    func uncleanExitAsks() {
        var named: [String] = []

        let launch = SafeModeLaunch.decide(shiftHeld: false, lastRunBundles: ["A.tingraplugin", "B.tingraplugin"]) {
            named = $0
            return .safeMode
        }

        #expect(named == ["A.tingraplugin", "B.tingraplugin"])
        #expect(launch == SafeModeLaunch(trigger: .afterUncleanExit, offerAnswer: .safeMode))
    }

    @Test("Open Normally after an unclean exit is a normal launch that remembers the answer")
    func openNormally() {
        let launch = SafeModeLaunch.decide(shiftHeld: false, lastRunBundles: ["A.tingraplugin"]) { _ in .normally }

        #expect(launch.trigger == nil)
        #expect(launch.offerAnswer == .normally)
        #expect(launch != .normal)
    }

    @Test("each answer is reported as its button's tap, and no offer reports nothing")
    func offerTaps() async {
        let eventBus = EventBus()
        let events = eventBus.events()

        SafeModeLaunch(trigger: .afterUncleanExit, offerAnswer: .safeMode).reportOfferTap(on: eventBus)
        SafeModeLaunch(offerAnswer: .normally).reportOfferTap(on: eventBus)
        SafeModeLaunch(trigger: .shiftKey).reportOfferTap(on: eventBus)
        let received = await drain(eventBus, events)

        #expect(received.map(\.name) == ["uncleanExitSafeMode.button", "uncleanExitNormal.button"])
        #expect(received.allSatisfy { $0.group == .tap && $0.domain == .plugIn })
    }

    @Test("the alert names the loaded plug-ins without their extension, then explains safe mode")
    func informativeTextNamesThePlugIns() {
        let text = UncleanExitAlert.informativeText(bundles: ["Fixture.tingraplugin", "NDI.tingraplugin"])

        #expect(text.contains("Fixture"))
        #expect(text.contains("NDI"))
        #expect(!text.contains(".tingraplugin"))
        #expect(text.hasSuffix("Nothing is removed."))
    }

    @Test("with no names in the record, the alert only explains safe mode")
    func informativeTextWithoutNames() {
        let text = UncleanExitAlert.informativeText(bundles: [])

        #expect(text.hasPrefix("Safe mode opens Tingra"))
    }
}

@Suite("PlugInLaunchRecord")
struct PlugInLaunchRecordTests {
    /// A record over a temporary folder.
    private func record() -> PlugInLaunchRecord {
        PlugInLaunchRecord(directory: URL.temporaryDirectory.appending(path: "tingra-launch-\(UUID().uuidString)"))
    }

    @Test("no file is no record")
    func missingFileIsNoRecord() {
        #expect(record().read() == nil)
    }

    @Test("the bundles written are the bundles read, until the record is removed")
    func writeReadRemove() {
        let record = record()
        defer { try? FileManager.default.removeItem(at: record.fileURL.deletingLastPathComponent()) }

        record.write(bundles: ["A.tingraplugin", "B.tingraplugin"])
        let read = record.read()
        record.remove()

        #expect(read == ["A.tingraplugin", "B.tingraplugin"])
        #expect(record.read() == nil)
        #expect(record.fileURL.lastPathComponent == "loaded-plug-ins.json")
    }

    @Test("a file that does not decode is still a record, naming no bundle")
    func undecodableFileIsARecord() throws {
        let record = record()
        defer { try? FileManager.default.removeItem(at: record.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: record.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: record.fileURL)

        #expect(record.read() == [])
    }

    @Test("the file's one key is bundles, and it round-trips")
    func contentsRoundTrip() throws {
        let contents = PlugInLaunchRecord.Contents(bundles: ["A.tingraplugin"])

        let data = try JSONEncoder().encode(contents)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["bundles"])
        #expect(try JSONDecoder().decode(PlugInLaunchRecord.Contents.self, from: data) == contents)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PlugInLaunchRecord.Contents.self, from: Data("{}".utf8))
        }
    }
}
