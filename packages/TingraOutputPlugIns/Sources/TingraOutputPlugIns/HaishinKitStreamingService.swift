//
//  HaishinKitStreamingService.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreMedia
import HaishinKit
import RTMPHaishinKit
import TingraPlugInKit
import VideoToolbox

/// The HaishinKit-backed `StreamingService`: RTMP/RTMPS delivery with
/// compression inside HaishinKit (VideoToolbox for video, AAC conversion
/// for audio) — the concrete implementation behind the output seam, and
/// the only type tree in the monorepo that touches HaishinKit
/// (ARCHITECTURE.md, "How HaishinKit is incorporated").
///
/// The seam facts this implementation builds on were verified by the
/// de-risking spike (TODO.md): uncompressed video enters as a
/// `CMSampleBuffer` and keeps its session-timeline PTS through the
/// encoder; LPCM audio must enter as `AVAudioPCMBuffer` + `AVAudioTime`
/// (HaishinKit's `CMSampleBuffer` audio path drops LPCM when the output
/// codec is AAC); RTMP timestamps are per-track deltas baselined at each
/// track's first buffer.
public actor HaishinKitStreamingService: StreamingService {
    /// The session's compression and program settings, applied to the
    /// stream's video and audio codec settings at start.
    private let configuration: StreamConfiguration

    /// The live RTMP connection, while started.
    private var connection: RTMPConnection?

    /// The live RTMP stream, while publishing.
    private var stream: RTMPStream?

    /// Watches the connection's status stream for loss, while started.
    private var monitorTask: Task<Void, Never>?

    /// Whether the service is currently publishing — appends and loss
    /// reports are gated on it.
    private var active = false

    /// The events consumers receive (see ``events``).
    private let eventStream: AsyncStream<StreamingServiceEvent>

    /// The continuation connection losses are reported through.
    private let eventContinuation: AsyncStream<StreamingServiceEvent>.Continuation

    /// The service's connection events; a single consumer is expected
    /// (the stream session). Finishes when the service stops.
    public nonisolated var events: AsyncStream<StreamingServiceEvent> { eventStream }

    /// Creates a service for one stream session.
    ///
    /// - Parameter configuration: The session's compression and program
    ///   settings.
    public init(configuration: StreamConfiguration) {
        HaishinKitLogging.configure()
        self.configuration = configuration
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: StreamingServiceEvent.self)
    }

    /// Connects and publishes: RTMP handshake, then the publish that
    /// validates the stream key. Calling it again after a reported loss
    /// reconnects with the same configuration.
    ///
    /// Throws ``StreamingServiceError`` — never an error carrying the
    /// stream key (failure reasons are built from RTMP status codes, not
    /// descriptions that could echo the publish name).
    public func start(to destination: Destination) async throws {
        await closeTransport()
        let endpoint = try Self.endpoint(for: destination)

        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        do {
            try await stream.setVideoSettings(Self.videoSettings(for: configuration))
            try await stream.setAudioSettings(Self.audioSettings(for: configuration))
        } catch {
            throw StreamingServiceError.unsupportedDestination(
                "The compression settings were rejected: \(String(describing: error))."
            )
        }
        do {
            _ = try await connection.connect(endpoint.command)
            _ = try await stream.publish(endpoint.streamName)
        } catch {
            try? await connection.close()
            throw StreamingServiceError.connectionRejected(
                Self.rejectionReason(for: error, destination: destination)
            )
        }

        self.connection = connection
        self.stream = stream
        active = true
        monitorTask = Task { [weak self] in
            // The status stream carries close/error codes; the stream
            // simply ending means the socket died without one. Either way,
            // a loss after a successful start is reported, never thrown.
            for await status in await connection.status {
                if Self.isConnectionLoss(code: status.code) {
                    await self?.reportLoss(reason: status.code)
                    return
                }
            }
            await self?.reportLoss(reason: "the connection closed")
        }
    }

    /// Appends one program video frame: wrapped as an uncompressed
    /// `CMSampleBuffer` carrying its session-timeline PTS; HaishinKit
    /// compresses it internally. Dropped silently while not publishing
    /// (during a reconnect gap).
    public func send(video frame: CapturedFrame) async {
        guard active, let stream else { return }
        guard let sampleBuffer = Self.videoSampleBuffer(for: frame, frameRate: configuration.frameRate) else {
            return
        }
        await stream.append(sampleBuffer)
    }

    /// Appends program audio: converted to `AVAudioPCMBuffer` +
    /// `AVAudioTime` (the form HaishinKit's AAC path requires — see the
    /// spike findings in TODO.md), the PTS carried as host time. Dropped
    /// silently while not publishing.
    public func send(audio buffer: CapturedAudio) async {
        guard active, let stream else { return }
        guard let (pcmBuffer, when) = Self.pcmBuffer(for: buffer) else { return }
        await stream.append(pcmBuffer, when: when)
    }

    /// The live delivery counters from HaishinKit's stream info.
    public func statistics() async -> StreamingStatistics {
        guard let stream else {
            return StreamingStatistics(bytesSent: 0, bytesPerSecond: 0, framesPerSecond: 0)
        }
        let info = await stream.info
        let fps = await stream.currentFPS
        return StreamingStatistics(
            bytesSent: Int(info.byteCount),
            bytesPerSecond: Int(info.currentBytesPerSecond),
            framesPerSecond: Int(fps)
        )
    }

    /// Stops streaming: flushes compression, closes the connection, and
    /// finishes the events stream. Safe to call more than once.
    public func stop() async {
        await closeTransport()
        eventContinuation.finish()
    }

    /// Closes the live transport without finishing the events stream —
    /// shared by ``stop()`` and the fresh-connection path of a reconnect.
    private func closeTransport() async {
        active = false
        monitorTask?.cancel()
        monitorTask = nil
        if let stream {
            _ = try? await stream.close()
        }
        if let connection {
            try? await connection.close()
        }
        stream = nil
        connection = nil
    }

    /// Reports a connection loss once per live start; the monitor calls
    /// this and the session decides whether to reconnect.
    private func reportLoss(reason: String) {
        guard active else { return }
        active = false
        eventContinuation.yield(.connectionLost(reason: reason))
    }

    // MARK: - Destination handling

    /// The RTMP endpoint for a destination: the connect command (the app
    /// URL) and the publish stream name.
    ///
    /// With a stream key, the URL is the app and the key is the name
    /// (CLI.md: `--url rtmp://live.twitch.tv/app --key …`). Without one,
    /// the URL's last path component is the name (a destination like
    /// `rtmp://host/app/streamName`). Neither form ever logs the name.
    ///
    /// Throws ``StreamingServiceError/unsupportedDestination(_:)`` when no
    /// stream name can be derived.
    static func endpoint(for destination: Destination) throws -> (command: String, streamName: String) {
        if let key = destination.streamKey, !key.isEmpty {
            return (destination.url.absoluteString, key)
        }
        let path = destination.url.path()
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            throw StreamingServiceError.unsupportedDestination(
                """
                The RTMP destination needs a stream key (--key, --key-env, or --key-stdin) or a \
                stream name as the last component of the URL path (rtmp://host/app/name).
                """
            )
        }
        var appURL = destination.url
        appURL.deleteLastPathComponent()
        // deleteLastPathComponent leaves a trailing slash; the RTMP connect
        // command is the bare app URL.
        var command = appURL.absoluteString
        if command.hasSuffix("/") {
            command = String(command.dropLast())
        }
        guard let streamName = components.last else {
            throw StreamingServiceError.unsupportedDestination(
                "The RTMP destination URL has no stream name path component."
            )
        }
        return (command, streamName)
    }

    /// A rejection reason safe to surface: built from RTMP status codes
    /// and error cases, never from descriptions that could echo the
    /// publish name (the stream key).
    static func rejectionReason(for error: any Error, destination: Destination) -> String {
        let host = destination.url.host() ?? destination.url.absoluteString
        switch error {
        case RTMPConnection.Error.requestFailed(let response):
            if let code = response.status?.code {
                return "The destination '\(host)' rejected the connection (\(code))."
            }
            return "The destination '\(host)' rejected the connection."
        case RTMPStream.Error.requestFailed(let response):
            if let code = response.status?.code {
                return "The destination '\(host)' rejected the publish (\(code)) — check the stream key."
            }
            return "The destination '\(host)' rejected the publish — check the stream key."
        case RTMPConnection.Error.connectionTimedOut, RTMPConnection.Error.requestTimedOut,
            RTMPStream.Error.requestTimedOut:
            return "The connection to '\(host)' timed out."
        case RTMPConnection.Error.socketErrorOccurred:
            return "The destination '\(host)' could not be reached."
        default:
            return "The destination '\(host)' could not be reached or rejected the handshake."
        }
    }

    /// Whether an RTMP status code on the connection means the link is
    /// gone (`NetConnection.Connect.Closed` and its failure variants).
    static func isConnectionLoss(code: String) -> Bool {
        code == "NetConnection.Connect.Closed"
            || code == "NetConnection.Connect.Failed"
            || code == "NetConnection.Connect.AppShutdown"
    }

    // MARK: - Settings mapping

    /// HaishinKit video codec settings for a stream configuration: size,
    /// bitrate, profile (High for H.264, Main for HEVC — never the
    /// Baseline default), keyframe interval, and expected frame rate.
    static func videoSettings(for configuration: StreamConfiguration) -> VideoCodecSettings {
        let profileLevel =
            switch configuration.videoCodec {
            case .h264: kVTProfileLevel_H264_High_AutoLevel as String
            case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel as String
            }
        return VideoCodecSettings(
            videoSize: CGSize(width: configuration.width, height: configuration.height),
            bitRate: configuration.videoBitsPerSecond,
            profileLevel: profileLevel,
            maxKeyFrameIntervalDuration: Int32(configuration.keyframeInterval),
            expectedFrameRate: Double(configuration.frameRate)
        )
    }

    /// HaishinKit audio codec settings for a stream configuration: AAC at
    /// the configured bitrate and sample rate.
    static func audioSettings(for configuration: StreamConfiguration) -> AudioCodecSettings {
        AudioCodecSettings(
            bitRate: configuration.audioBitsPerSecond,
            sampleRate: Float64(configuration.audioSampleRate),
            format: .aac
        )
    }

    // MARK: - Buffer conversion

    /// Wraps a program frame's pixel buffer in an uncompressed
    /// `CMSampleBuffer` carrying the frame's session-timeline PTS, the
    /// form HaishinKit compresses internally. Returns nil if Core Media
    /// cannot create the wrapper — a failed frame is skipped, never fatal.
    static func videoSampleBuffer(for frame: CapturedFrame, frameRate: Int) -> CMSampleBuffer? {
        var formatOut: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescriptionOut: &formatOut
            ) == noErr,
            let format = formatOut
        else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: frame.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleOut: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.pixelBuffer,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sampleOut
            ) == noErr
        else { return nil }
        return sampleOut
    }

    /// Converts LPCM program audio into the `AVAudioPCMBuffer` +
    /// `AVAudioTime` pair HaishinKit's AAC path requires, the
    /// session-timeline PTS carried as the `AVAudioTime`'s host time.
    /// Returns nil for a non-PCM buffer or a failed copy — skipped, never
    /// fatal.
    static func pcmBuffer(for audio: CapturedAudio) -> (AVAudioPCMBuffer, AVAudioTime)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(audio.sampleBuffer) else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(audio.sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                audio.sampleBuffer,
                at: 0,
                frameCount: Int32(frames),
                into: buffer.mutableAudioBufferList
            ) == noErr
        else { return nil }
        let seconds = max(0, audio.presentationTime.seconds)
        let when = AVAudioTime(
            hostTime: AVAudioTime.hostTime(forSeconds: seconds),
            sampleTime: AVAudioFramePosition(seconds * format.sampleRate),
            atRate: format.sampleRate
        )
        return (buffer, when)
    }
}
