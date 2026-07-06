//
//  StreamPlan.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraCapturePlugIns
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// Where the stream key will come from at connect time. The key value
/// itself never appears in a plan, an event, or any output.
enum KeySource: String, Sendable {
    /// No key: the destination does not require one.
    case none

    /// Inline via `--key`.
    case option

    /// From an environment variable via `--key-env`.
    case environment

    /// Read from standard input at connect time via `--key-stdin`
    /// (`--dry-run` deliberately does not read it).
    case stdin
}

/// The validated `stream` configuration a plan is resolved from — the
/// parsed option surface, framework-free so tests construct it directly.
struct StreamRequest: Sendable {
    /// The destination URL string (already scheme-validated).
    var url: String

    /// Where the stream key will come from.
    var keySource: KeySource = .none

    /// The `--camera` selector, if given.
    var camera: String?

    /// The `--mic` selector, if given.
    var mic: String?

    /// Audio-only stream (`--no-video`).
    var noVideo = false

    /// Video-only stream (`--no-audio`).
    var noAudio = false

    /// The video generator standing in for a camera, if given.
    var videoGenerator: VideoGeneratorKind?

    /// The audio generator standing in for a microphone, if given.
    var audioGenerator: AudioGeneratorKind?

    /// The program resolution.
    var resolution = Resolution(width: 1920, height: 1080)

    /// The program frame rate.
    var fps = 30

    /// The video codec.
    var videoCodec = VideoCodec.h264

    /// The video bitrate.
    var videoBitrate = Bitrate(bitsPerSecond: 4_500_000)

    /// The keyframe interval in seconds.
    var keyframeInterval = 2

    /// The audio codec.
    var audioCodec = AudioCodec.aac

    /// The audio bitrate.
    var audioBitrate = Bitrate(bitsPerSecond: 160_000)

    /// The audio sample rate in Hertz.
    var audioSamplerate = 48_000

    /// Reconnection attempts on connection loss.
    var reconnect = 3

    /// Delay between reconnection attempts, in seconds.
    var reconnectDelay = 2

    /// The `--record` file path, if given.
    var record: String?

    /// Automatic stop after this many seconds, if given.
    var duration: Int?

    /// How often stats print, in seconds (0 disables).
    var statsInterval = 5

    /// The log file path, if given.
    var logFile: String?
}

/// The system default inputs, injected so plan tests never touch
/// AVFoundation (production reads `SystemDefaultInputs`).
struct SystemDefaultProvider: Sendable {
    /// The system default camera's identifier, or nil without a camera.
    let cameraID: @Sendable () -> InputID?

    /// The system default microphone's identifier, or nil without one.
    let microphoneID: @Sendable () -> InputID?

    /// The production provider, backed by the capture plug-in package.
    static let system = SystemDefaultProvider(
        cameraID: { SystemDefaultInputs.cameraID },
        microphoneID: { SystemDefaultInputs.microphoneID }
    )
}

/// Errors from plan resolution that are not selector errors.
enum StreamPlanError: Error, Equatable {
    /// No selector was given and no device of the kind is connected to
    /// default to.
    case noDefaultInput(InputKind)
}

extension StreamPlanError {
    /// The stable error identifier this error reports under (see CLI.md,
    /// "Error identifiers").
    var identifier: ErrorIdentifier {
        switch self {
        case .noDefaultInput: return .inputNotFound
        }
    }
}

extension StreamPlanError: CustomStringConvertible {
    var description: String {
        switch self {
        case .noDefaultInput(let kind):
            let flag = kind == .camera ? "--camera" : "--mic"
            let generator = kind == .camera ? "--video-generator bars" : "--audio-generator tone"
            return """
                No \(kind.rawValue) is connected to default to. Connect one, select one with \
                \(flag), or use `\(generator)` to stream without hardware.
                """
        }
    }
}

/// The resolved `stream` pipeline configuration `--dry-run` reports: every
/// selector resolved against the registry, every default filled in —
/// nothing started, nothing connected (CLI.md).
struct StreamPlan: Sendable {
    /// One resolved input: the stable identifier and user-facing name.
    struct ResolvedInput: Sendable, Equatable {
        /// The input's stable identifier.
        let id: String

        /// The input's user-facing name.
        let name: String
    }

    /// The request the plan was resolved from.
    let request: StreamRequest

    /// The resolved video input, or nil under `--no-video`.
    let video: ResolvedInput?

    /// The resolved audio input, or nil under `--no-audio`.
    let audio: ResolvedInput?

    /// Resolves a request against the registry: explicit selectors first,
    /// generators by their stable identifiers, system defaults otherwise.
    ///
    /// Throws `InputSelectorError` when a selector matches nothing or too
    /// much, and ``StreamPlanError/noDefaultInput(_:)`` when defaulting
    /// finds no device.
    static func resolve(
        request: StreamRequest,
        registry: InputRegistry,
        defaults: SystemDefaultProvider
    ) async throws -> StreamPlan {
        /// Resolves one side (video or audio) of the pipeline.
        func resolveSide(
            disabled: Bool,
            generator: String?,
            selector: String?,
            kind: InputKind,
            defaultID: InputID?
        ) async throws -> ResolvedInput? {
            guard !disabled else { return nil }
            let input: any Input
            if let generator {
                input = try await registry.resolveInput(selector: generator, ofKind: .generator)
            } else if let selector {
                input = try await registry.resolveInput(selector: selector, ofKind: kind)
            } else if let defaultID {
                input = try await registry.resolveInput(selector: defaultID.rawValue, ofKind: kind)
            } else {
                throw StreamPlanError.noDefaultInput(kind)
            }
            return ResolvedInput(id: input.id.rawValue, name: input.name)
        }

        let video = try await resolveSide(
            disabled: request.noVideo,
            generator: request.videoGenerator?.rawValue,
            selector: request.camera,
            kind: .camera,
            defaultID: defaults.cameraID()
        )
        let audio = try await resolveSide(
            disabled: request.noAudio,
            generator: request.audioGenerator?.rawValue,
            selector: request.mic,
            kind: .microphone,
            defaultID: defaults.microphoneID()
        )
        return StreamPlan(request: request, video: video, audio: audio)
    }

    /// The plan as `stream.plan` event params — flat, stable keys (a
    /// scripting contract, see CLI.md "stream --dry-run"). The video and
    /// audio blocks are omitted entirely when that side is disabled; the
    /// stream key never appears, only its source.
    var eventParams: [String: EventValue] {
        var params: [String: EventValue] = [
            "url": .string(request.url),
            "keySource": .string(request.keySource.rawValue),
            "reconnect": .int(request.reconnect),
            "reconnectDelay": .int(request.reconnectDelay),
            "statsInterval": .int(request.statsInterval),
        ]
        if let duration = request.duration {
            params["duration"] = .int(duration)
        }
        if let record = request.record {
            params["record"] = .string(record)
        }
        if let logFile = request.logFile {
            params["logFile"] = .string(logFile)
        }
        if let video {
            params["videoInput"] = .string(video.id)
            params["videoInputName"] = .string(video.name)
            params["resolution"] = .string(request.resolution.description)
            params["fps"] = .int(request.fps)
            params["videoCodec"] = .string(request.videoCodec.rawValue)
            params["videoBitrate"] = .int(request.videoBitrate.bitsPerSecond)
            params["keyframeInterval"] = .int(request.keyframeInterval)
        }
        if let audio {
            params["audioInput"] = .string(audio.id)
            params["audioInputName"] = .string(audio.name)
            params["audioCodec"] = .string(request.audioCodec.rawValue)
            params["audioBitrate"] = .int(request.audioBitrate.bitsPerSecond)
            params["audioSamplerate"] = .int(request.audioSamplerate)
        }
        return params
    }

    /// The human-readable plan, the command result on standard output in
    /// human mode.
    var humanDescription: String {
        var lines = ["DRY RUN — resolved plan; nothing started, nothing connected"]
        lines.append("DESTINATION")
        lines.append(row("url", request.url))
        lines.append(row("key", keySourceDescription))
        lines.append(row("reconnect", "\(request.reconnect) attempts, \(request.reconnectDelay)s delay"))
        lines.append("VIDEO")
        if let video {
            lines.append(row("input", "\(video.name)  (id: \(video.id))"))
            lines.append(row("resolution", request.resolution.description))
            lines.append(row("fps", "\(request.fps)"))
            lines.append(row("codec", request.videoCodec.rawValue))
            lines.append(row("bitrate", request.videoBitrate.description))
            lines.append(row("keyframe interval", "\(request.keyframeInterval)s"))
        } else {
            lines.append(row("input", "(disabled by --no-video)"))
        }
        lines.append("AUDIO")
        if let audio {
            lines.append(row("input", "\(audio.name)  (id: \(audio.id))"))
            lines.append(row("codec", request.audioCodec.rawValue))
            lines.append(row("bitrate", request.audioBitrate.description))
            lines.append(row("sample rate", "\(request.audioSamplerate) Hz"))
        } else {
            lines.append(row("input", "(disabled by --no-audio)"))
        }
        lines.append("CONTROL")
        lines.append(row("duration", request.duration.map { "\($0)s" } ?? "until stopped"))
        lines.append(row("record", request.record ?? "(disabled)"))
        lines.append(
            row("stats interval", request.statsInterval == 0 ? "disabled" : "\(request.statsInterval)s")
        )
        if let logFile = request.logFile {
            lines.append(row("log file", logFile))
        }
        return lines.joined(separator: "\n")
    }

    /// How the key row reads in the human plan.
    private var keySourceDescription: String {
        switch request.keySource {
        case .none: return "(none)"
        case .option: return "provided with --key (value never printed)"
        case .environment: return "from the --key-env environment variable"
        case .stdin: return "read from stdin at connect time"
        }
    }

    /// One aligned `label  value` row of the human plan.
    private func row(_ label: String, _ value: String) -> String {
        let padding = String(repeating: " ", count: max(1, 19 - label.count))
        return "  \(label)\(padding)\(value)"
    }
}
