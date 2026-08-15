//
//  StreamStartToolTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraMCP

/// The `stream_start` argument parsing and validation — the same rules the
/// CLI's `stream` validation enforces, expressed as identifier-keyed tool
/// errors.
@Suite("stream_start parsing")
struct StreamStartToolTests {
    /// The tool error thrown by parsing the given arguments, or nil if it
    /// parsed cleanly.
    private func parseError(_ arguments: JSONValue) -> ToolError? {
        do {
            _ = try StreamStartTool.parse(arguments)
            return nil
        } catch let error as ToolError {
            return error
        } catch {
            return ToolError(identifier: .pipelineError, message: "\(error)")
        }
    }

    @Test("a minimal request defaults both sides to the system default input")
    func minimalRequest() throws {
        let request = try StreamStartTool.parse(["url": "rtmp://localhost/live"])
        #expect(request.destinations.count == 1)
        #expect(request.destinations.first == .raw(id: "destination-1", url: "rtmp://localhost/live", key: nil))
        #expect(request.video == .systemDefault)
        #expect(request.audio == .systemDefault)
        #expect(request.configuration.width == 1920)
        #expect(request.configuration.height == 1080)
        #expect(request.configuration.videoBitsPerSecond == 4_500_000)
    }

    @Test("a missing url returns an invalidArgument error")
    func missingURL() {
        #expect(parseError(["fps": 30])?.identifier == .invalidArgument)
    }

    @Test("a destinations array becomes one leg per entry, numbered by position")
    func destinationsArrayFansOut() throws {
        let request = try StreamStartTool.parse([
            "destinations": .array([
                .object(["url": .string("rtmp://localhost/live"), "key": .string("twitch_key")]),
                .object(["url": .string("srt://localhost:8890")]),
            ])
        ])

        #expect(request.destinations.count == 2)
        #expect(request.destinations[0] == .raw(id: "destination-1", url: "rtmp://localhost/live", key: "twitch_key"))
        #expect(request.destinations[1] == .raw(id: "destination-2", url: "srt://localhost:8890", key: nil))
    }

    @Test("url and destinations together return an invalidArgument error")
    func bothDestinationFormsReturnAnError() {
        let error = parseError([
            "url": .string("rtmp://localhost/live"),
            "destinations": .array([.object(["url": .string("rtmp://localhost/backup")])]),
        ])
        #expect(error?.identifier == .invalidArgument)
    }

    @Test("a destination selector becomes one saved leg, numbered like any other")
    func savedDestinationSelector() throws {
        let request = try StreamStartTool.parse(["destination": "Twitch"])
        #expect(request.destinations == [.saved(id: "destination-1", selector: "Twitch")])
    }

    @Test("url and destination together return an invalidArgument error")
    func urlAndSelectorReturnAnError() {
        let error = parseError(["url": .string("rtmp://localhost/live"), "destination": .string("Twitch")])
        #expect(error?.identifier == .invalidArgument)
    }

    @Test("destination and destinations together return an invalidArgument error")
    func selectorAndArrayReturnAnError() {
        let error = parseError([
            "destination": .string("Twitch"),
            "destinations": .array([.object(["url": .string("rtmp://localhost/backup")])]),
        ])
        #expect(error?.identifier == .invalidArgument)
    }

    @Test("a key alongside a destination selector returns an invalidArgument error")
    func keyWithSelectorReturnsAnError() {
        let error = parseError(["destination": .string("Twitch"), "key": .string("live_abc123")])
        #expect(error?.identifier == .invalidArgument)
        #expect(error?.message.contains("carries its own stream key") == true)
    }

    @Test("a destinations array mixes saved and raw legs, each resolving on its own")
    func destinationsArrayMixesForms() throws {
        let request = try StreamStartTool.parse([
            "destinations": .array([
                .object(["destination": .string("Twitch")]),
                .object(["url": .string("rtmp://localhost/backup"), "key": .string("backup_key")]),
            ])
        ])

        #expect(request.destinations[0] == .saved(id: "destination-1", selector: "Twitch"))
        #expect(request.destinations[1] == .raw(id: "destination-2", url: "rtmp://localhost/backup", key: "backup_key"))
    }

    @Test("a destinations entry naming both a url and a destination returns an invalidArgument error")
    func destinationEntryNamingTwoPlaces() {
        let error = parseError([
            "destinations": .array([
                .object(["url": .string("rtmp://localhost/live"), "destination": .string("Twitch")])
            ])
        ])
        #expect(error?.identifier == .invalidArgument)
    }

    @Test("a destinations entry with a key beside a saved destination returns an invalidArgument error")
    func destinationEntryKeyWithSelector() {
        let error = parseError([
            "destinations": .array([
                .object(["destination": .string("Twitch"), "key": .string("live_abc123")])
            ])
        ])
        #expect(error?.identifier == .invalidArgument)
    }

    @Test("an empty destinations array returns an invalidArgument error")
    func emptyDestinationsReturnsAnError() {
        #expect(parseError(["destinations": .array([])])?.identifier == .invalidArgument)
    }

    @Test("a destinations entry that is not an object with a url returns an invalidArgument error")
    func malformedDestinationEntryReturnsAnError() {
        #expect(
            parseError(["destinations": .array([.string("rtmp://localhost/live")])])?.identifier == .invalidArgument)
        #expect(parseError(["destinations": .array([.object(["key": .string("k")])])])?.identifier == .invalidArgument)
    }

    @Test("every destination's scheme is checked, not just the first")
    func everyDestinationSchemeIsChecked() {
        let error = parseError([
            "destinations": .array([
                .object(["url": .string("rtmp://localhost/live")]),
                .object(["url": .string("http://example.com")]),
            ])
        ])
        #expect(error?.identifier == .invalidArgument)
    }

    @Test("an unsupported url scheme returns an invalidArgument error")
    func badScheme() {
        #expect(parseError(["url": "http://example.com"])?.identifier == .invalidArgument)
    }

    @Test("noVideo and noAudio together return an error")
    func nothingToStream() {
        #expect(parseError(["url": "rtmp://h/l", "noVideo": true, "noAudio": true])?.identifier == .invalidArgument)
    }

    @Test("camera and videoGenerator together return an error")
    func conflictingVideoInputs() {
        #expect(
            parseError(["url": "rtmp://h/l", "camera": "BRIO", "videoGenerator": "bars"])?.identifier
                == .invalidArgument
        )
    }

    @Test("the bars generator resolves to the bars input selection")
    func videoGeneratorSelection() throws {
        let request = try StreamStartTool.parse([
            "url": "rtmp://h/l", "videoGenerator": "bars", "audioGenerator": "tone",
        ])
        #expect(request.video == .generator(InputID(rawValue: "bars")))
        #expect(request.audio == .generator(InputID(rawValue: "tone")))
    }

    @Test("an explicit camera selector becomes a device selection")
    func cameraSelection() throws {
        let request = try StreamStartTool.parse(["url": "rtmp://h/l", "camera": "BRIO"])
        #expect(request.video == .device(selector: "BRIO"))
    }

    @Test("noVideo disables the video side")
    func noVideoDisables() throws {
        let request = try StreamStartTool.parse(["url": "rtmp://h/l", "noVideo": true])
        #expect(request.video == .disabled)
        #expect(request.audio == .systemDefault)
    }

    @Test("odd resolution dimensions return an error")
    func oddResolution() {
        #expect(parseError(["url": "rtmp://h/l", "resolution": "1281x720"])?.identifier == .invalidArgument)
    }

    @Test("a WxH resolution parses to its dimensions")
    func resolutionParsing() throws {
        let request = try StreamStartTool.parse(["url": "rtmp://h/l", "resolution": "1280x720"])
        #expect(request.configuration.width == 1280)
        #expect(request.configuration.height == 720)
    }

    @Test("a bitrate accepts both a suffix string and a bare integer")
    func bitrateForms() throws {
        let suffix = try StreamStartTool.parse(["url": "rtmp://h/l", "videoBitrate": "6000k"])
        #expect(suffix.configuration.videoBitsPerSecond == 6_000_000)
        let integer = try StreamStartTool.parse(["url": "rtmp://h/l", "videoBitrate": 3_000_000])
        #expect(integer.configuration.videoBitsPerSecond == 3_000_000)
    }

    @Test("hevc is accepted and an unknown codec returns an error")
    func videoCodec() throws {
        let hevc = try StreamStartTool.parse(["url": "rtmp://h/l", "videoCodec": "hevc"])
        #expect(hevc.configuration.videoCodec == .hevc)
        #expect(parseError(["url": "rtmp://h/l", "videoCodec": "av1"])?.identifier == .invalidArgument)
    }

    @Test("a negative reconnect count returns an error")
    func negativeReconnect() {
        #expect(parseError(["url": "rtmp://h/l", "reconnect": -1])?.identifier == .invalidArgument)
    }

    @Test("the policy carries the reconnect, stats, and duration values")
    func policyValues() throws {
        let request = try StreamStartTool.parse([
            "url": "rtmp://h/l", "reconnect": 5, "reconnectDelay": 3, "statsInterval": 10, "duration": 30,
        ])
        #expect(request.policy.reconnectAttempts == 5)
        #expect(request.policy.reconnectDelaySeconds == 3)
        #expect(request.policy.statsIntervalSeconds == 10)
        #expect(request.policy.durationSeconds == 30)
    }

    // MARK: - Recording (the `record` field — MCP.md, "Tool surface")

    @Test("a record path rides alongside a destination")
    func recordAlongsideDestination() throws {
        let request = try StreamStartTool.parse(["url": "rtmp://h/l", "record": "/Movies/show.mp4"])
        #expect(request.destinations.count == 1)
        #expect(request.recording?.url.path == "/Movies/show.mp4")
        #expect(request.recording?.fileExtension == "mp4")
    }

    @Test("a record path alone is a record-only request with no destinations")
    func recordOnlyRequest() throws {
        let request = try StreamStartTool.parse(["record": "/Movies/show.mov"])
        #expect(request.destinations.isEmpty)
        #expect(request.recording?.url.path == "/Movies/show.mov")
        #expect(request.recording?.fileExtension == "mov")
    }

    @Test("a leading tilde expands against the home directory")
    func tildeRecordPathExpands() throws {
        let request = try StreamStartTool.parse(["record": "~/Movies/show.mp4"])
        let expected = URL.homeDirectory.appending(path: "Movies/show.mp4").path
        #expect(request.recording?.url.path == expected)
    }

    @Test("a relative record path returns an invalidArgument error")
    func relativeRecordPath() {
        #expect(parseError(["record": "Movies/show.mp4"])?.identifier == .invalidArgument)
    }

    @Test("a record path with an unsupported extension returns an invalidArgument error")
    func unsupportedRecordExtension() {
        #expect(parseError(["url": "rtmp://h/l", "record": "/Movies/show.avi"])?.identifier == .invalidArgument)
    }

    @Test("a request with neither a destination nor a record returns an invalidArgument error")
    func nothingToFeed() {
        #expect(parseError(.object([:]))?.identifier == .invalidArgument)
    }

    @Test("the track topology carries into the configuration for the recording sink")
    func topologyCarriesIntoConfiguration() throws {
        let request = try StreamStartTool.parse([
            "url": "rtmp://h/l", "noVideo": true, "record": "/Movies/audio-take.mp4",
        ])
        #expect(request.configuration.includesVideo == false)
        #expect(request.configuration.includesAudio == true)
    }
}
