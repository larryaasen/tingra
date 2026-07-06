//
//  StreamOptionValuesTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

// Darwin, not Foundation: Foundation's `Stream` would shadow the command
// type under test (the module and its root type share the `TingraCLI`
// name, so qualified lookup cannot disambiguate).
import Darwin
import Testing

@testable import TingraCLI

@Suite("Resolution parsing")
struct ResolutionTests {
    @Test("parses the WxH form, case-insensitively")
    func parsesWxH() {
        #expect(Resolution(argument: "1920x1080") == Resolution(width: 1920, height: 1080))
        #expect(Resolution(argument: "1280X720") == Resolution(width: 1280, height: 720))
    }

    @Test(
        "rejects malformed and non-positive forms",
        arguments: ["1920", "x1080", "1920x", "0x0", "-1x9", "axb", "1x2x3"])
    func rejectsMalformed(argument: String) {
        #expect(Resolution(argument: argument) == nil)
    }

    @Test("evenness reflects the 4:2:0 delivery rule")
    func evenness() {
        #expect(Resolution(width: 1920, height: 1080).isEven)
        #expect(!Resolution(width: 1921, height: 1080).isEven)
        #expect(!Resolution(width: 1920, height: 1081).isEven)
    }

    @Test("describes itself in the canonical WxH form")
    func descriptionForm() {
        #expect(Resolution(width: 1920, height: 1080).description == "1920x1080")
    }
}

@Suite("Bitrate parsing")
struct BitrateTests {
    @Test("parses k and M suffixes and bare bits per second")
    func parsesSuffixForms() {
        #expect(Bitrate(argument: "4500k") == Bitrate(bitsPerSecond: 4_500_000))
        #expect(Bitrate(argument: "160K") == Bitrate(bitsPerSecond: 160_000))
        #expect(Bitrate(argument: "6M") == Bitrate(bitsPerSecond: 6_000_000))
        #expect(Bitrate(argument: "2500000") == Bitrate(bitsPerSecond: 2_500_000))
    }

    @Test("rejects malformed and non-positive forms", arguments: ["", "k", "-500k", "0", "4.5M", "fastk"])
    func rejectsMalformed(argument: String) {
        #expect(Bitrate(argument: argument) == nil)
    }

    @Test("describes whole kilobit rates compactly")
    func descriptionForm() {
        #expect(Bitrate(bitsPerSecond: 4_500_000).description == "4500k")
        #expect(Bitrate(bitsPerSecond: 4_500_001).description == "4500001")
    }
}

@Suite("Stream option validation")
struct StreamValidationTests {
    /// Parses a `stream` invocation (validation runs during parse); the
    /// base arguments make a minimal valid dry run.
    private func parse(_ extra: [String], url: String = "rtmp://localhost/live") throws -> Stream {
        try Stream.parse(["--url", url, "--dry-run"] + extra)
    }

    @Test("a minimal invocation parses with the CLI.md defaults")
    func defaultsMatchCLIMD() throws {
        let stream = try parse([])
        #expect(stream.resolution == Resolution(width: 1920, height: 1080))
        #expect(stream.fps == 30)
        #expect(stream.videoCodec == .h264)
        #expect(stream.videoBitrate == Bitrate(bitsPerSecond: 4_500_000))
        #expect(stream.keyframeInterval == 2)
        #expect(stream.audioCodec == .aac)
        #expect(stream.audioBitrate == Bitrate(bitsPerSecond: 160_000))
        #expect(stream.audioSamplerate == 48_000)
        #expect(stream.reconnect == 3)
        #expect(stream.reconnectDelay == 2)
        #expect(stream.statsInterval == 5)
    }

    @Test("rtmp, rtmps, and srt URLs are accepted")
    func acceptedSchemes() throws {
        _ = try parse([], url: "rtmp://live.twitch.tv/app")
        _ = try parse([], url: "rtmps://a.rtmps.youtube.com/live2")
        _ = try parse([], url: "srt://ingest.example.com:8890?streamid=publish:mystream")
    }

    @Test("an unsupported URL scheme throws a usage error")
    func rejectedScheme() {
        #expect(throws: (any Error).self) {
            _ = try parse([], url: "ftp://example.com")
        }
    }

    @Test("key sources are mutually exclusive")
    func keySourcesConflict() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--key", "a", "--key-stdin"])
        }
    }

    @Test("--key-env requires the variable to be set")
    func keyEnvMustExist() throws {
        setenv("TINGRA_TEST_STREAM_KEY", "live_test", 1)
        defer { unsetenv("TINGRA_TEST_STREAM_KEY") }
        _ = try parse(["--key-env", "TINGRA_TEST_STREAM_KEY"])

        #expect(throws: (any Error).self) {
            _ = try parse(["--key-env", "TINGRA_TEST_STREAM_KEY_ABSENT"])
        }
    }

    @Test("--no-video and --no-audio together throw")
    func disablingBothThrows() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--no-video", "--no-audio"])
        }
    }

    @Test("--no-video conflicts with camera selection and video generators")
    func noVideoConflicts() {
        #expect(throws: (any Error).self) { _ = try parse(["--no-video", "--camera", "0"]) }
        #expect(throws: (any Error).self) { _ = try parse(["--no-video", "--video-generator", "bars"]) }
    }

    @Test("a camera selector and a video generator conflict")
    func cameraAndGeneratorConflict() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--camera", "0", "--video-generator", "bars"])
        }
    }

    @Test("the PLUGE video generator parses as a stable identifier")
    func plugeGeneratorParses() throws {
        let stream = try parse(["--video-generator", "pluge"])
        #expect(stream.videoGenerator == .pluge)
    }

    @Test("the alignment video generator parses as a stable identifier")
    func alignmentGeneratorParses() throws {
        let stream = try parse(["--video-generator", "alignment"])
        #expect(stream.videoGenerator == .alignment)
    }

    @Test("the strict PLUGE video generator parses as a stable identifier")
    func plugeStrictGeneratorParses() throws {
        let stream = try parse(["--video-generator", "pluge-strict"])
        #expect(stream.videoGenerator == .plugeStrict)
    }

    @Test("odd program dimensions throw — 4:2:0 delivery requires even")
    func oddResolutionThrows() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--resolution", "1921x1080"])
        }
    }

    @Test(
        "non-positive rates and intervals throw",
        arguments: [
            ["--fps", "0"],
            ["--keyframe-interval", "0"],
            ["--audio-samplerate", "0"],
            ["--reconnect", "-1"],
            ["--duration", "0"],
        ])
    func nonPositiveValuesThrow(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try parse(arguments)
        }
    }

    @Test("--verbose and --quiet conflict")
    func verboseQuietConflict() {
        #expect(throws: (any Error).self) {
            _ = try parse(["--verbose", "--quiet"])
        }
    }

    @Test("the request mirrors the parsed key source")
    func requestKeySource() throws {
        #expect(try parse([]).request.keySource == .none)
        #expect(try parse(["--key", "live_x"]).request.keySource == .option)
        #expect(try parse(["--key-stdin"]).request.keySource == .stdin)
    }
}
