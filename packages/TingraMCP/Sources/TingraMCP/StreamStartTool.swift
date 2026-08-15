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

/// The `stream_start` tool: go live to one or more destinations, mirroring
/// the `tingra-cli stream` options (CLI.md). Returns the session id
/// `stream_status` and `stream_stop` key off. One active stream — a
/// conflicting start returns a structured error naming the active session.
///
/// Several destinations are **one session with N legs**, so a fan-out still
/// returns a single id (MCP.md, "Sessions and concurrency"). Name them either
/// with the `url`/`key` pair (one destination, the common case) or with the
/// `destinations` array; passing both is an error.
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
        "Start capturing and streaming to one or more RTMP/RTMPS/SRT destinations. Mirrors `tingra-cli stream`. "
        + "Returns a session id used by stream_status and stream_stop. One active stream at a time; several "
        + "destinations are one session fanned out, reported per destination by stream_status. Pass 'record' "
        + "to also write the program to a local file — alone, with no destination, it records without streaming."

    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "url": schema(
                "string",
                "RTMP(S) or SRT destination URL, e.g. rtmp://live.twitch.tv/app. Use this for a single "
                    + "destination, or 'destinations' for several — not both."),
            "key": schema("string", "Stream key for 'url'. Never returned or logged."),
            "destinations": .object([
                "type": .string("array"),
                "description": .string(
                    "Several destinations for one program. Each item is an object with a required 'url' and an "
                        + "optional 'key'. Use instead of 'url'/'key', not alongside them."),
                "items": .object([
                    "type": .string("object"),
                    "required": .array([.string("url")]),
                    "properties": .object([
                        "url": schema("string", "RTMP(S) or SRT destination URL."),
                        "key": schema("string", "Stream key for this destination. Never returned or logged."),
                    ]),
                ]),
            ]),
            "record": schema(
                "string",
                "File path for a simultaneous local recording (.mov/.mp4 — the extension selects the "
                    + "container). Absolute, or starting with '~/'. Prefer ~/Movies: Desktop, Documents, and "
                    + "Downloads are privacy-protected on macOS and may prompt or refuse. With 'record' and no "
                    + "destination, the session records without streaming."),
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
        let destinations = try parseDestinations(reader)
        let recording = try parseRecord(reader.string("record"))
        guard !destinations.isEmpty || recording != nil else {
            throw invalid(
                "stream_start needs a destination ('url' or 'destinations'), a 'record' path, or both — "
                    + "with neither there is nothing to feed.")
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

        // The track topology (noVideo/noAudio) is carried so a recording
        // sink opens only the tracks the program has — the same reason the
        // CLI's stream configuration carries it (CLI.md, "--record").
        let configuration = StreamConfiguration(
            width: width,
            height: height,
            frameRate: fps,
            videoCodec: videoCodec,
            videoBitsPerSecond: videoBitrate,
            keyframeInterval: keyframeInterval,
            audioCodec: .aac,
            audioBitsPerSecond: audioBitrate,
            audioSampleRate: audioSamplerate,
            includesVideo: !noVideo,
            includesAudio: !noAudio
        )
        let policy = StreamSession.Policy(
            reconnectAttempts: reconnect,
            reconnectDelaySeconds: reconnectDelay,
            statsIntervalSeconds: statsInterval,
            durationSeconds: duration
        )
        return StreamRequest(
            destinations: destinations,
            recording: recording,
            video: video,
            audio: audio,
            configuration: configuration,
            policy: policy
        )
    }

    /// Parses the destinations from either the `url`/`key` pair or the
    /// `destinations` array, validating each URL's scheme.
    ///
    /// At most one of the two forms may be given: accepting both would leave
    /// the order (and therefore each leg's identity) ambiguous. **Neither is
    /// legal too** — that is a record-only request, and `parse` enforces
    /// that something (a destination or a recording) is configured.
    ///
    /// - Parameter reader: The `stream_start` arguments.
    /// - Returns: The requested destinations, numbered by position; empty
    ///   when neither form was given.
    /// - Throws: A ``ToolError`` with `invalidArgument` for a duplicated,
    ///   malformed, or unsupported destination.
    private static func parseDestinations(_ reader: ArgumentReader) throws -> [RequestedDestination] {
        let single = reader.string("url")
        let list = reader.value("destinations")?.arrayValue

        if single != nil, list != nil {
            throw invalid("Pass either 'url' (one destination) or 'destinations' (several), not both.")
        }
        if let single {
            return [try makeDestination(url: single, key: reader.string("key"), index: 0)]
        }
        guard let list else { return [] }
        guard !list.isEmpty else {
            throw invalid("'destinations' is empty; name at least one destination to stream to.")
        }
        return try list.enumerated().map { index, item in
            guard let members = item.objectValue, let url = members["url"]?.stringValue else {
                throw invalid("Each 'destinations' item must be an object with a string 'url'.")
            }
            return try makeDestination(url: url, key: members["key"]?.stringValue, index: index)
        }
    }

    /// Validates one destination's URL and pairs it with its key and its
    /// position-derived leg id.
    ///
    /// - Parameters:
    ///   - url: The destination URL string.
    ///   - key: The stream key for it, if given.
    ///   - index: The zero-based position, which names the leg.
    /// - Returns: The validated destination.
    /// - Throws: A ``ToolError`` for a malformed URL or unsupported scheme.
    private static func makeDestination(url: String, key: String?, index: Int) throws -> RequestedDestination {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else {
            throw invalid("The 'url' value is not a valid URL: '\(url)'.")
        }
        guard ["rtmp", "rtmps", "srt"].contains(scheme) else {
            throw invalid("The 'url' scheme '\(scheme)' is not supported; use rtmp://, rtmps://, or srt://.")
        }
        return RequestedDestination(id: "destination-\(index + 1)", url: url, streamKey: key)
    }

    /// Validates the `record` path and resolves it to a recording request.
    ///
    /// The path must be absolute, with a leading `~/` expanded against the
    /// daemon's home — the operator's, since the daemon is a LaunchAgent in
    /// their GUI session — as the one convenience (MCP.md, "Tool surface").
    /// Anything else is refused: the daemon's working directory is
    /// meaningless, and JSON has no shell to expand for the caller. The
    /// extension is validated here (`mov`/`mp4`, the CLI's parse-time rule);
    /// the coordinator resolves it against the output registry.
    ///
    /// - Parameter value: The `record` argument, if given.
    /// - Returns: The validated recording request, or nil when absent.
    /// - Throws: A ``ToolError`` with `invalidArgument` for a relative path
    ///   or an unsupported extension.
    private static func parseRecord(_ value: String?) throws -> RequestedRecording? {
        guard let value else { return nil }
        let url: URL
        if value.hasPrefix("~/") {
            url = URL.homeDirectory.appending(path: String(value.dropFirst(2)))
        } else if value.hasPrefix("/") {
            url = URL(filePath: value)
        } else {
            throw invalid(
                "The 'record' path must be absolute or start with '~/': '\(value)'. The daemon has no "
                    + "meaningful working directory to resolve a relative path against.")
        }
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "mov" || fileExtension == "mp4" else {
            throw invalid(
                "The 'record' path must end in .mov or .mp4 — the extension selects the container: '\(value)'.")
        }
        return RequestedRecording(url: url, fileExtension: fileExtension)
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

    /// The optional `sessionId` argument shared by `stream_status` and
    /// `stream_stop`: nil when absent (or JSON null) — address the active
    /// stream — and the id when given.
    ///
    /// - Parameter tool: The calling tool's name, for the error message.
    /// - Returns: The session id, or nil to address the active stream.
    /// - Throws: A ``ToolError`` with `invalidArgument` when the value is
    ///   present but not a string — a malformed call, not an omission.
    func sessionId(tool: String) throws -> String? {
        guard let value = members["sessionId"], value != .null else { return nil }
        guard let id = value.stringValue else {
            throw ToolError(
                identifier: .invalidArgument,
                message: "\(tool)'s 'sessionId' must be a string when given; omit it to address the active stream."
            )
        }
        return id
    }
}
