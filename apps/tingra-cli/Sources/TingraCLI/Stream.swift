//
//  Stream.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import TingraCapturePlugIns
import TingraEventBus
import TingraGeneratorPlugIns
import TingraHost
import TingraOutputPlugIns
import TingraPlugInKit

/// `tingra-cli stream` — start capture and stream until stopped (CLI.md):
/// Ctrl-C / SIGTERM stops cleanly (flushing compression and closing the
/// connection), `--duration` stops automatically, and `--dry-run` reports
/// the resolved plan without connecting.
struct Stream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start streaming (the main one shot command)."
    )

    // MARK: Destination

    @Option(help: "RTMP(S) or SRT destination URL, e.g. rtmp://live.twitch.tv/app.")
    var url: String

    @Option(help: "Stream key, appended to the RTMP URL path. Prefer --key-env or --key-stdin in scripts.")
    var key: String?

    @Option(help: "Read the stream key from this environment variable.")
    var keyEnv: String?

    @Flag(help: "Read the stream key from standard input.")
    var keyStdin = false

    @Option(help: "Reconnection attempts on connection loss (0 disables).")
    var reconnect: Int = 3

    @Option(help: "Delay between reconnection attempts, in seconds.")
    var reconnectDelay: Int = 2

    // MARK: Input selection

    @Option(help: "Camera by index, unique name substring, or ID from devices --json. Default: system default camera.")
    var camera: String?

    @Option(help: "Microphone, same selector forms. Default: system default input.")
    var mic: String?

    @Flag(help: "Audio only stream.")
    var noVideo = false

    @Flag(help: "Video only stream.")
    var noAudio = false

    @Option(help: "A video generator instead of a camera (bars: SMPTE color bars with timecode).")
    var videoGenerator: VideoGeneratorKind?

    @Option(help: "An audio generator instead of a microphone (tone: 440 Hz).")
    var audioGenerator: AudioGeneratorKind?

    // MARK: Compression

    @Option(help: "Program resolution as WxH.")
    var resolution = Resolution(width: 1920, height: 1080)

    @Option(help: "Frame rate.")
    var fps: Int = 30

    @Option(help: "Video codec: h264 (broadest support) or hevc.")
    var videoCodec: VideoCodec = .h264

    @Option(help: "Video bitrate, e.g. 6000k.")
    var videoBitrate = Bitrate(bitsPerSecond: 4_500_000)

    @Option(help: "Keyframe interval in seconds.")
    var keyframeInterval: Int = 2

    @Option(help: "Audio codec (aac only in v1).")
    var audioCodec: AudioCodec = .aac

    @Option(help: "Audio bitrate, e.g. 160k.")
    var audioBitrate = Bitrate(bitsPerSecond: 160_000)

    @Option(help: "Audio sample rate in Hz.")
    var audioSamplerate: Int = 48_000

    // MARK: Recording and control

    @Option(help: "Stop automatically after this many seconds.")
    var duration: Int?

    @Flag(help: "Resolve inputs, report the resolved plan, and exit without connecting.")
    var dryRun = false

    // MARK: Output and logging

    @Flag(help: "Emit newline delimited JSON status events instead of human readable logs.")
    var json = false

    @Option(help: "How often to print bitrate/fps/dropped frame stats, in seconds (0 disables).")
    var statsInterval: Int = 5

    @Flag(help: "Show every event group on the console.")
    var verbose = false

    @Flag(help: "Show errors only on the console.")
    var quiet = false

    @Option(help: "Also write logs to a file.")
    var logFile: String?

    /// Flag/option validation — syntactic and cross-flag rules; exit 64 on
    /// failure (CLI.md exit codes). Selector resolution happens later,
    /// against the registry, and reports through the event bus.
    func validate() throws {
        guard let destination = URL(string: url), let scheme = destination.scheme?.lowercased() else {
            throw ValidationError("The --url value is not a valid URL: '\(url)'.")
        }
        guard ["rtmp", "rtmps", "srt"].contains(scheme) else {
            throw ValidationError(
                "The --url scheme '\(scheme)' is not supported; use rtmp://, rtmps://, or srt://."
            )
        }
        let keySources = [key != nil, keyEnv != nil, keyStdin].count(where: { $0 })
        guard keySources <= 1 else {
            throw ValidationError("Pass at most one of --key, --key-env, and --key-stdin.")
        }
        if let keyEnv {
            guard let value = ProcessInfo.processInfo.environment[keyEnv], !value.isEmpty else {
                throw ValidationError("The --key-env variable '\(keyEnv)' is not set (or is empty).")
            }
        }
        guard !(noVideo && noAudio) else {
            throw ValidationError("--no-video and --no-audio together leave nothing to stream.")
        }
        if noVideo {
            guard camera == nil, videoGenerator == nil else {
                throw ValidationError("--no-video conflicts with --camera and --video-generator.")
            }
        }
        if noAudio {
            guard mic == nil, audioGenerator == nil else {
                throw ValidationError("--no-audio conflicts with --mic and --audio-generator.")
            }
        }
        guard !(camera != nil && videoGenerator != nil) else {
            throw ValidationError("Pass either --camera or --video-generator, not both.")
        }
        guard !(mic != nil && audioGenerator != nil) else {
            throw ValidationError("Pass either --mic or --audio-generator, not both.")
        }
        guard resolution.isEven else {
            throw ValidationError(
                "The --resolution dimensions must be even (4:2:0 delivery requires it): '\(resolution)'."
            )
        }
        guard fps > 0 else { throw ValidationError("--fps must be positive.") }
        guard keyframeInterval > 0 else { throw ValidationError("--keyframe-interval must be positive.") }
        guard audioSamplerate > 0 else { throw ValidationError("--audio-samplerate must be positive.") }
        guard reconnect >= 0 else { throw ValidationError("--reconnect cannot be negative.") }
        guard reconnectDelay >= 0 else { throw ValidationError("--reconnect-delay cannot be negative.") }
        guard statsInterval >= 0 else { throw ValidationError("--stats-interval cannot be negative.") }
        if let duration {
            guard duration > 0 else { throw ValidationError("--duration must be positive.") }
        }
        guard !(verbose && quiet) else {
            throw ValidationError("--verbose and --quiet conflict.")
        }
    }

    /// The validated option surface as a plan request.
    var request: StreamRequest {
        var request = StreamRequest(url: url)
        if key != nil {
            request.keySource = .option
        } else if keyEnv != nil {
            request.keySource = .environment
        } else if keyStdin {
            request.keySource = .stdin
        }
        request.camera = camera
        request.mic = mic
        request.noVideo = noVideo
        request.noAudio = noAudio
        request.videoGenerator = videoGenerator
        request.audioGenerator = audioGenerator
        request.resolution = resolution
        request.fps = fps
        request.videoCodec = videoCodec
        request.videoBitrate = videoBitrate
        request.keyframeInterval = keyframeInterval
        request.audioCodec = audioCodec
        request.audioBitrate = audioBitrate
        request.audioSamplerate = audioSamplerate
        request.reconnect = reconnect
        request.reconnectDelay = reconnectDelay
        request.duration = duration
        request.statsInterval = statsInterval
        request.logFile = logFile
        return request
    }

    func run() async throws {
        let eventBus = EventBus()
        // Human mode keeps the console to errors (the plan on stdout is the
        // command result); --json emits the standard event stream; --verbose
        // opens every group, --quiet narrows to errors in both modes.
        let consoleGroups: Set<EventGroup> =
            if quiet {
                [.error]
            } else if verbose {
                Set(EventGroup.allCases)
            } else if json {
                ConsoleSink.defaultGroups
            } else {
                [.error]
            }
        let consoleTask = eventBus.attach(ConsoleSink(mode: json ? .json : .human, groups: consoleGroups))
        // Skipped when standard error is a terminal — the OS's own
        // terminal mirror already echoes this process's events there, so
        // attaching would double them (see EVENTS.md, "OSLog sink"); it
        // remains the system of record for non-interactive runs.
        let osLogTask = OSLogAttachment.attachIfNeeded(to: eventBus)
        let fileTask = logFile.map { eventBus.attach(FileSink(path: $0)) }

        /// Drains every sink so no buffered event is lost before exit.
        func drainSinks() async {
            eventBus.shutdown()
            await consoleTask.value
            if let osLogTask {
                await osLogTask.value
            }
            if let fileTask {
                await fileTask.value
            }
        }

        let registry = InputRegistry()
        let outputs = OutputRegistry()
        let clock = HostClock()
        let context = PlugInContext(eventBus: eventBus, clock: clock, inputs: registry, outputs: outputs)
        await PlugInLoader().activate(
            [AVFoundationCapturePlugIn(), GeneratorPlugIn(), HaishinKitOutputPlugIn()],
            in: context
        )

        do {
            let plan = try await StreamPlan.resolve(
                request: request,
                registry: registry,
                defaults: .system
            )
            if dryRun {
                eventBus.event("stream.plan", domain: .session, params: plan.eventParams)
                if !json {
                    print(plan.humanDescription)
                }
                await drainSinks()
                return
            }
            let outcome = try await goLive(
                plan: plan,
                registry: registry,
                outputs: outputs,
                clock: clock,
                eventBus: eventBus
            )
            if outcome == .connectionLost {
                eventBus.error(
                    "stream.connection",
                    domain: .output,
                    params: [
                        "identifier": .string(ErrorIdentifier.connectionLost.rawValue),
                        "message": .string(
                            "The connection was lost and not recovered within \(reconnect) reconnect attempts."
                        ),
                    ]
                )
                await drainSinks()
                throw ExitCode(ErrorIdentifier.connectionLost.exitCode)
            }
            await drainSinks()
        } catch let exitCode as ExitCode {
            throw exitCode
        } catch {
            let identifier = Self.identifier(for: error)
            let (name, domain) = Self.errorEvent(for: error)
            eventBus.error(
                name,
                domain: domain,
                params: [
                    "identifier": .string(identifier.rawValue),
                    "message": .string(String(describing: error)),
                ]
            )
            await drainSinks()
            throw ExitCode(identifier.exitCode)
        }
    }

    /// Connects and streams until stopped: builds the destination and the
    /// session from the resolved plan, wires Ctrl-C / SIGTERM to a clean
    /// stop, and returns why the session ended.
    private func goLive(
        plan: StreamPlan,
        registry: InputRegistry,
        outputs: OutputRegistry,
        clock: HostClock,
        eventBus: EventBus
    ) async throws -> StreamSession.Outcome {
        // The URL parsed at validation; the scheme resolves the provider.
        guard let destinationURL = URL(string: request.url), let scheme = destinationURL.scheme?.lowercased()
        else {
            throw StreamingServiceError.unsupportedDestination("The --url value is not a valid URL.")
        }
        guard let provider = await outputs.provider(forScheme: scheme) else {
            throw StreamingServiceError.unsupportedDestination(
                """
                No registered output serves '\(scheme)://' destinations in v1 — SRT output arrives \
                at roadmap step 8. Stream to an rtmp:// or rtmps:// destination.
                """
            )
        }

        // The key is read only here, at connect time, and only ever handed
        // to the destination — never an event param, never printed.
        let streamKey = try StreamKey.read(option: key, environmentVariable: keyEnv, stdin: keyStdin)
        let destination = Destination(url: destinationURL, streamKey: streamKey)

        var videoInput: (any Input)?
        if let video = plan.video {
            videoInput = await registry.input(withID: InputID(rawValue: video.id))
        }
        var audioInput: (any Input)?
        if let audio = plan.audio {
            audioInput = await registry.input(withID: InputID(rawValue: audio.id))
        }

        let configuration = streamConfiguration
        let session = StreamSession(
            videoInput: videoInput,
            audioInput: audioInput,
            service: provider.makeStreamingService(configuration: configuration),
            destination: destination,
            configuration: configuration,
            policy: StreamSession.Policy(
                reconnectAttempts: reconnect,
                reconnectDelaySeconds: reconnectDelay,
                statsIntervalSeconds: statsInterval,
                durationSeconds: duration
            ),
            clock: clock,
            eventBus: eventBus
        )

        // Ctrl-C / SIGTERM is a clean stop: flush compression, close the
        // connection, exit 0 (CLI.md exit codes).
        let signalTask = Task {
            await TerminationSignal.wait()
            await session.stop()
        }
        defer { signalTask.cancel() }
        return try await session.run()
    }

    /// The session's stream configuration from the validated options.
    private var streamConfiguration: StreamConfiguration {
        StreamConfiguration(
            width: resolution.width,
            height: resolution.height,
            frameRate: fps,
            videoCodec: videoCodec == .hevc ? .hevc : .h264,
            videoBitsPerSecond: videoBitrate.bitsPerSecond,
            keyframeInterval: keyframeInterval,
            audioCodec: .aac,
            audioBitsPerSecond: audioBitrate.bitsPerSecond,
            audioSampleRate: audioSamplerate
        )
    }

    /// The stable error identifier for a stream failure.
    private static func identifier(for error: any Error) -> ErrorIdentifier {
        switch error {
        case let selectorError as InputSelectorError:
            return selectorError.identifier
        case let planError as StreamPlanError:
            return planError.identifier
        case let captureError as CaptureInputError:
            return captureError.identifier
        case let serviceError as StreamingServiceError:
            return serviceError.identifier
        case let keyError as StreamKeyError:
            return keyError.identifier
        default:
            return .pipelineError
        }
    }

    /// The event name and domain a stream failure reports under: input
    /// and authorization problems belong to capture, everything at or
    /// past the connection belongs to output.
    private static func errorEvent(for error: any Error) -> (name: String, domain: EventDomain) {
        switch error {
        case is InputSelectorError, is StreamPlanError:
            return ("input.resolve", .capture)
        case is CaptureInputError:
            return ("input.start", .capture)
        default:
            return ("stream.start", .output)
        }
    }
}

extension ErrorIdentifier {
    /// The exit code carrying this identifier's meaning to shells (the
    /// CLI.md "Error identifiers" registry, code column).
    var exitCode: Int32 {
        switch self {
        case .invalidArgument: return 64
        case .inputNotFound, .inputAmbiguous, .authorizationDenied: return 69
        case .connectionFailed, .connectionLost: return 75
        default: return 70
        }
    }
}
