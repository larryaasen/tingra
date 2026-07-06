//
//  StreamStartToolTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

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
        #expect(request.url == "rtmp://localhost/live")
        #expect(request.video == .systemDefault)
        #expect(request.audio == .systemDefault)
        #expect(request.configuration.width == 1920)
        #expect(request.configuration.height == 1080)
        #expect(request.configuration.videoBitsPerSecond == 4_500_000)
        #expect(request.streamKey == nil)
    }

    @Test("a missing url returns an invalidArgument error")
    func missingURL() {
        #expect(parseError(["fps": 30])?.identifier == .invalidArgument)
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
}
