//
//  StreamStartTool.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost
import TingraPlugInKit

/// The `stream_start` tool: go live to a destination, mirroring the
/// `tingra-cli stream` options (CLI.md). Returns the session id
/// `stream_status` and `stream_stop` key off. One active stream in v1 — a
/// conflicting start returns a structured error naming the active session.
///
/// The tool parses and validates the MCP arguments (the same rules as the
/// CLI's flag validation) into a ``StreamRequest``, then hands it to the
/// shared ``StreamCoordinator``, which reuses the host's ``StreamSession``.
struct StreamStartTool: Tool {
    /// The coordinator owning the one active stream.
    private let coordinator: StreamCoordinator

    /// Creates the tool over the shared coordinator.
    init(coordinator: StreamCoordinator) {
        self.coordinator = coordinator
    }

    let name = "stream_start"
    let title = "Start Streaming"
    let description =
        "Start capturing and streaming to an RTMP/RTMPS destination. Mirrors `tingra-cli stream`. "
        + "Returns a session id used by stream_status and stream_stop. One active stream at a time."

    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([.string("url")]),
        "properties": .object([
            "url": schema("string", "RTMP(S) destination URL, e.g. rtmp://live.twitch.tv/app."),
            "key": schema("string", "Stream key. Passed to secure storage; never returned or logged."),
            "camera": schema(
                "string", "Camera selector: index, unique name substring, or ID. Default: system default."),
            "mic": schema("string", "Microphone selector, same forms. Default: system default."),
            "videoGenerator": schema(
                "string",
                "Use a video generator instead of a camera, e.g. 'bars', 'alignment', 'pluge', 'pluge-strict'."),
            "audioGenerator": schema("string", "Use an audio generator instead of a microphone, e.g. 'tone'."),
            "noVideo": schema("boolean", "Audio-only stream."),
            "noAudio": schema("boolean", "Video-only stream."),
            "resolution": schema("string", "Program resolution as WxH (default 1920x1080)."),
            "fps": schema("integer", "Frame rate (default 30)."),
            "videoCodec": schema("string", "Video codec: 'h264' (default) or 'hevc'."),
            "videoBitrate": .object([
                "description": .string("Video bitrate in bits/second, or a '4500k'/'6M' string (default 4500k).")
            ]),
            "keyframeInterval": schema("integer", "Keyframe interval in seconds (default 2)."),
            "audioCodec": schema("string", "Audio codec: 'aac' (only option in v1)."),
            "audioBitrate": .object([
                "description": .string("Audio bitrate in bits/second, or a '160k' string (default 160k).")
            ]),
            "audioSamplerate": schema("integer", "Audio sample rate in Hz (default 48000)."),
            "reconnect": schema("integer", "Reconnection attempts on connection loss (default 3, 0 disables)."),
            "reconnectDelay": schema("integer", "Delay between reconnection attempts in seconds (default 2)."),
            "duration": schema("integer", "Stop automatically after this many seconds."),
            "statsInterval": schema("integer", "How often stream.stats notifications fire, in seconds (default 5)."),
        ]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        let request = try Self.parse(arguments)
        let sessionId = try await coordinator.start(request)
        return .object(["sessionId": .string(sessionId)])
    }

    /// A JSON Schema property node with a type and description.
    private static func schema(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    /// Parses and validates the arguments into a ``StreamRequest``, throwing
    /// a ``ToolError`` with `invalidArgument` for any bad or conflicting
    /// value — the same rules the CLI's `stream` validation enforces.
    static func parse(_ arguments: JSONValue) throws -> StreamRequest {
        let reader = ArgumentReader(arguments)

        guard let url = reader.string("url") else {
            throw invalid("stream_start requires a string 'url'.")
        }
        guard let scheme = URL(string: url)?.scheme?.lowercased() else {
            throw invalid("The 'url' value is not a valid URL: '\(url)'.")
        }
        guard ["rtmp", "rtmps", "srt"].contains(scheme) else {
            throw invalid("The 'url' scheme '\(scheme)' is not supported; use rtmp://, rtmps://, or srt://.")
        }

        let noVideo = reader.bool("noVideo") ?? false
        let noAudio = reader.bool("noAudio") ?? false
        guard !(noVideo && noAudio) else {
            throw invalid("noVideo and noAudio together leave nothing to stream.")
        }

        let camera = reader.string("camera")
        let mic = reader.string("mic")
        let videoGenerator = reader.string("videoGenerator")
        let audioGenerator = reader.string("audioGenerator")

        if noVideo, camera != nil || videoGenerator != nil {
            throw invalid("noVideo conflicts with camera and videoGenerator.")
        }
        if noAudio, mic != nil || audioGenerator != nil {
            throw invalid("noAudio conflicts with mic and audioGenerator.")
        }
        guard !(camera != nil && videoGenerator != nil) else {
            throw invalid("Pass either camera or videoGenerator, not both.")
        }
        guard !(mic != nil && audioGenerator != nil) else {
            throw invalid("Pass either mic or audioGenerator, not both.")
        }

        // A generator name is the generator's stable input id (CLI.md, "Input
        // selection"); it is resolved against the generator registry, which
        // returns an inputNotFound tool error for an unknown name — so this
        // tool automatically tracks whatever generators are registered
        // without a hardcoded list to drift.
        let video: SideSelection =
            noVideo
            ? .disabled
            : videoGenerator.map { SideSelection.generator(InputID(rawValue: $0)) }
                ?? camera.map { SideSelection.device(selector: $0) } ?? .systemDefault
        let audio: SideSelection =
            noAudio
            ? .disabled
            : audioGenerator.map { SideSelection.generator(InputID(rawValue: $0)) }
                ?? mic.map { SideSelection.device(selector: $0) } ?? .systemDefault

        let (width, height) = try parseResolution(reader.string("resolution"))
        let fps = try positive(reader.int("fps"), default: 30, field: "fps")
        let videoCodec = try parseVideoCodec(reader.string("videoCodec"))
        let videoBitrate = try parseBitrate(reader.value("videoBitrate"), default: 4_500_000, field: "videoBitrate")
        let keyframeInterval = try positive(reader.int("keyframeInterval"), default: 2, field: "keyframeInterval")
        try parseAudioCodec(reader.string("audioCodec"))
        let audioBitrate = try parseBitrate(reader.value("audioBitrate"), default: 160_000, field: "audioBitrate")
        let audioSamplerate = try positive(reader.int("audioSamplerate"), default: 48_000, field: "audioSamplerate")

        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw invalid("The resolution dimensions must be even (4:2:0 delivery requires it): '\(width)x\(height)'.")
        }

        let reconnect = try nonNegative(reader.int("reconnect"), default: 3, field: "reconnect")
        let reconnectDelay = try nonNegative(reader.int("reconnectDelay"), default: 2, field: "reconnectDelay")
        let statsInterval = try nonNegative(reader.int("statsInterval"), default: 5, field: "statsInterval")
        var duration: Int?
        if let value = reader.int("duration") {
            guard value > 0 else { throw invalid("duration must be positive.") }
            duration = value
        }

        let configuration = StreamConfiguration(
            width: width,
            height: height,
            frameRate: fps,
            videoCodec: videoCodec,
            videoBitsPerSecond: videoBitrate,
            keyframeInterval: keyframeInterval,
            audioCodec: .aac,
            audioBitsPerSecond: audioBitrate,
            audioSampleRate: audioSamplerate
        )
        let policy = StreamSession.Policy(
            reconnectAttempts: reconnect,
            reconnectDelaySeconds: reconnectDelay,
            statsIntervalSeconds: statsInterval,
            durationSeconds: duration
        )
        return StreamRequest(
            url: url,
            streamKey: reader.string("key"),
            video: video,
            audio: audio,
            configuration: configuration,
            policy: policy
        )
    }

    /// Parses `WxH`, defaulting to 1920x1080.
    private static func parseResolution(_ value: String?) throws -> (width: Int, height: Int) {
        guard let value else { return (1920, 1080) }
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            throw invalid("The resolution must be WxH with positive dimensions, e.g. 1280x720: '\(value)'.")
        }
        return (width, height)
    }

    /// Parses a video codec, defaulting to H.264.
    private static func parseVideoCodec(_ value: String?) throws -> StreamConfiguration.VideoCodec {
        switch value {
        case nil, "h264": return .h264
        case "hevc": return .hevc
        default: throw invalid("videoCodec must be 'h264' or 'hevc'; got '\(value ?? "")'.")
        }
    }

    /// Validates the audio codec (AAC only in v1).
    private static func parseAudioCodec(_ value: String?) throws {
        guard value == nil || value == "aac" else {
            throw invalid("audioCodec must be 'aac' (the only option in v1); got '\(value ?? "")'.")
        }
    }

    /// Parses a bitrate from a bits-per-second integer or a `4500k`/`6M`
    /// string, defaulting when absent.
    private static func parseBitrate(_ value: JSONValue?, default def: Int, field: String) throws -> Int {
        guard let value else { return def }
        if let int = value.intValue {
            guard int > 0 else { throw invalid("\(field) must be positive.") }
            return int
        }
        guard let string = value.stringValue else {
            throw invalid("\(field) must be a bits-per-second integer or a '4500k'/'6M' string.")
        }
        let multiplier: Int
        var digits = string
        switch string.last {
        case "k", "K":
            multiplier = 1000
            digits = String(string.dropLast())
        case "m", "M":
            multiplier = 1_000_000
            digits = String(string.dropLast())
        default: multiplier = 1
        }
        guard let base = Int(digits), base > 0 else {
            throw invalid("\(field) is not a valid bitrate: '\(string)'.")
        }
        return base * multiplier
    }

    /// Validates a positive integer option, defaulting when absent.
    private static func positive(_ value: Int?, default def: Int, field: String) throws -> Int {
        guard let value else { return def }
        guard value > 0 else { throw invalid("\(field) must be positive.") }
        return value
    }

    /// Validates a non-negative integer option, defaulting when absent.
    private static func nonNegative(_ value: Int?, default def: Int, field: String) throws -> Int {
        guard let value else { return def }
        guard value >= 0 else { throw invalid("\(field) cannot be negative.") }
        return value
    }

    /// A tool error with the `invalidArgument` identifier.
    private static func invalid(_ message: String) -> ToolError {
        ToolError(identifier: .invalidArgument, message: message)
    }
}

/// A small reader over a `tools/call` arguments object, tolerating a missing
/// or non-object arguments value (both read as "no arguments").
struct ArgumentReader {
    /// The arguments members, or empty when none were sent.
    private let members: [String: JSONValue]

    /// Wraps the raw arguments value.
    init(_ arguments: JSONValue) {
        members = arguments.objectValue ?? [:]
    }

    /// The raw value for a key, if present.
    func value(_ key: String) -> JSONValue? { members[key] }

    /// The string value for a key, if present and a string.
    func string(_ key: String) -> String? { members[key]?.stringValue }

    /// The integer value for a key, if present and an integer.
    func int(_ key: String) -> Int? { members[key]?.intValue }

    /// The boolean value for a key, if present and a boolean.
    func bool(_ key: String) -> Bool? { members[key]?.boolValue }
}
