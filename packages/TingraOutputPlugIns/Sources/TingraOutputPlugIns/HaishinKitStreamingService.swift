//
//  HaishinKitStreamingService.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import HaishinKit
import RTMPHaishinKit
import TingraPlugInKit

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
            try await stream.setVideoSettings(HaishinKitMediaConversion.videoSettings(for: configuration))
            try await stream.setAudioSettings(HaishinKitMediaConversion.audioSettings(for: configuration))
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
        guard
            let sampleBuffer = HaishinKitMediaConversion.videoSampleBuffer(
                for: frame, frameRate: configuration.frameRate)
        else {
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
        guard let (pcmBuffer, when) = HaishinKitMediaConversion.pcmBuffer(for: buffer) else { return }
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
}
