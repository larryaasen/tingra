//
//  SRTHaishinKitStreamingService.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import Foundation
import HaishinKit
import SRTHaishinKit
import TingraPlugInKit

/// The HaishinKit-backed SRT `StreamingService`: SRT delivery with
/// compression inside HaishinKit (VideoToolbox for video, AAC for audio,
/// muxed to MPEG-TS) — the SRT sibling of ``HaishinKitStreamingService``
/// behind the same output seam (roadmap step 8).
///
/// The append surface and the compression settings are identical to the RTMP
/// service — `SRTStream` takes the same uncompressed video `CMSampleBuffer`
/// and the same `AVAudioPCMBuffer` + `AVAudioTime` audio — so buffer
/// conversion and settings mapping are shared through
/// ``HaishinKitMediaConversion`` rather than duplicated. Three things differ
/// from RTMP, and shape this type:
///
/// 1. **The stream key rides in the URL's `streamid`, not a publish name.**
///    SRT has no RTMP-style publish handshake; the key is composed into the
///    connect URL by ``srtURL(for:)`` (see that method for the `--key`
///    rule). The key never leaves this method and is never logged.
/// 2. **No mid-stream connection-loss push.** HaishinKit 2.x's SRT publish
///    path exposes no event when an established link later dies (unlike
///    RTMP's `connection.status` stream): `SRTConnection.connected` flips
///    false only on our own `close()`, and the ground-truth socket state is
///    private. So this service reports start-time failures (thrown), but its
///    ``events`` stream never yields ``StreamingServiceEvent/connectionLost``
///    — the session's reconnect machinery therefore does not fire on an SRT
///    outage in this iteration. Deferred, recorded in TODO.md; SRT's own ARQ
///    retransmission already rides out ordinary packet loss below this layer,
///    so the gap is only the hard-timeout case. Never a poll loop
///    (CLAUDE.md).
/// 3. **No frame-rate counter in the library.** `SRTStream` exposes no
///    `currentFPS`, so this service counts video appends itself and derives
///    the rate over the interval between ``statistics()`` reads.
public actor SRTHaishinKitStreamingService: StreamingService {
    /// The session's compression and program settings, applied to the
    /// stream's video and audio codec settings at start.
    private let configuration: StreamConfiguration

    /// The live SRT connection, while started.
    private var connection: SRTConnection?

    /// The live SRT stream, while publishing.
    private var stream: SRTStream?

    /// Whether the service is currently publishing — appends and stats are
    /// gated on it.
    private var active = false

    /// The events consumers receive (see ``events``). Created for protocol
    /// conformance and finished on ``stop()``; no ``StreamingServiceEvent``
    /// is ever yielded (see the type note: SRT exposes no loss push).
    private let eventStream: AsyncStream<StreamingServiceEvent>

    /// The continuation backing ``eventStream`` — only ever finished.
    private let eventContinuation: AsyncStream<StreamingServiceEvent>.Continuation

    /// Total video frames appended since the current start, the basis for
    /// the derived frame rate (see ``statistics()``).
    private var videoFrameCount = 0

    /// The previous ``statistics()`` sample — the frame count and the
    /// monotonic instant it was read at — used to derive the frame rate
    /// over the interval since. Nil until the first read, when the start
    /// instant is used instead.
    private var previousFPSSample: (count: Int, at: ContinuousClock.Instant)?

    /// The monotonic instant of the current start, the first frame-rate
    /// baseline. Wall-clock rate math only — never a media timestamp, so
    /// this is not the CLOCK.md master clock (see CLOCK.md, which governs
    /// PTS, not local rate measurement).
    private var startInstant: ContinuousClock.Instant?

    /// The clock the frame-rate interval is measured against (monotonic).
    private let rateClock = ContinuousClock()

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

    /// Connects and publishes: the SRT handshake (which carries and
    /// validates the `streamid`), then publish. Calling it again after a
    /// stop reconnects with the same configuration.
    ///
    /// Throws ``StreamingServiceError`` — never an error carrying the
    /// stream key (the rejection reason is built from the SRT reject reason
    /// and the destination host, never the composed URL that holds the
    /// `streamid`).
    public func start(to destination: Destination) async throws {
        await closeTransport()
        let url = try Self.srtURL(for: destination)

        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)
        do {
            try await stream.setVideoSettings(HaishinKitMediaConversion.videoSettings(for: configuration))
            try await stream.setAudioSettings(HaishinKitMediaConversion.audioSettings(for: configuration))
        } catch {
            throw StreamingServiceError.unsupportedDestination(
                "The compression settings were rejected: \(String(describing: error))."
            )
        }
        // Declare the program's track topology up front (like the recording
        // sink): the MPEG-TS muxer needs it before frames flow, where the
        // library would otherwise infer it only once a buffer of each kind
        // has arrived.
        await stream.setExpectedMedias(Self.expectedMedias(for: configuration))

        do {
            try await connection.connect(url)
        } catch {
            await connection.close()
            throw StreamingServiceError.connectionRejected(
                Self.rejectionReason(for: error, destination: destination)
            )
        }
        await stream.publish()

        self.connection = connection
        self.stream = stream
        active = true
        videoFrameCount = 0
        previousFPSSample = nil
        startInstant = rateClock.now
    }

    /// Appends one program video frame: wrapped as an uncompressed
    /// `CMSampleBuffer` carrying its session-timeline PTS; HaishinKit
    /// compresses it internally. Dropped silently while not publishing.
    public func send(video frame: CapturedFrame) async {
        guard active, let stream else { return }
        guard
            let sampleBuffer = HaishinKitMediaConversion.videoSampleBuffer(
                for: frame, frameRate: configuration.frameRate)
        else { return }
        videoFrameCount += 1
        await stream.append(sampleBuffer)
    }

    /// Appends program audio: converted to `AVAudioPCMBuffer` +
    /// `AVAudioTime` (the form HaishinKit's AAC path requires), the PTS
    /// carried as host time. Dropped silently while not publishing.
    public func send(audio buffer: CapturedAudio) async {
        guard active, let stream else { return }
        guard let (pcmBuffer, when) = HaishinKitMediaConversion.pcmBuffer(for: buffer) else { return }
        await stream.append(pcmBuffer, when: when)
    }

    /// A snapshot of the delivery counters: bytes from the connection's SRT
    /// performance data, and a frame rate derived from the video appends
    /// counted since the previous read (SRT exposes no `currentFPS`).
    public func statistics() async -> StreamingStatistics {
        let bytesSent = await Int(clamping: connection?.performanceData?.byteSentTotal ?? 0)
        let mbpsSendRate = await connection?.performanceData?.mbpsSendRate ?? 0
        // Megabits/second → bytes/second.
        let bytesPerSecond = Int((mbpsSendRate * 1_000_000) / 8)

        let now = rateClock.now
        let baseline = previousFPSSample ?? (count: 0, at: startInstant ?? now)
        let elapsed = baseline.at.duration(to: now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let framesPerSecond = seconds > 0 ? Int(Double(videoFrameCount - baseline.count) / seconds) : 0
        previousFPSSample = (count: videoFrameCount, at: now)

        return StreamingStatistics(
            bytesSent: bytesSent,
            bytesPerSecond: bytesPerSecond,
            framesPerSecond: max(0, framesPerSecond)
        )
    }

    /// Stops streaming: closes the connection and finishes the events
    /// stream. Safe to call more than once.
    public func stop() async {
        await closeTransport()
        eventContinuation.finish()
    }

    /// Closes the live transport without finishing the events stream —
    /// shared by ``stop()`` and the fresh-connection path of a reconnect.
    private func closeTransport() async {
        active = false
        if let stream {
            await stream.close()
        }
        if let connection {
            await connection.close()
        }
        stream = nil
        connection = nil
    }

    // MARK: - Destination handling

    /// The SRT connect URL for a destination: the destination URL with the
    /// stream key composed into the `streamid` query parameter.
    ///
    /// SRT carries the key in `streamid` (there is no RTMP-style publish
    /// name), so `--key` composes in per the rule (CLI.md, "Destination"):
    /// - A `--key` and a URL with **no** `streamid` → `streamid=<key>` is
    ///   appended.
    /// - A `--key` and a URL that **already** carries a `streamid` is
    ///   ambiguous → thrown as
    ///   ``StreamingServiceError/unsupportedDestination(_:)``; the caller
    ///   supplies the key one way, not both.
    /// - No `--key` → the URL is used as given (its own `streamid`, if any).
    ///
    /// The key is placed **literally**: HaishinKit reads `streamid` by raw
    /// string split with no percent-decoding, so the composed value must not
    /// be percent-encoded (a `publish:live/key` MediaMTX streamid stays
    /// `publish:live/key`). The key must therefore be URL-safe — the same
    /// literal-composition contract RTMP has for its publish name. The
    /// returned URL holds the secret and is never logged.
    static func srtURL(for destination: Destination) throws -> URL {
        let base = destination.url.absoluteString
        let hasStreamID = existingStreamID(in: base) != nil

        guard let key = destination.streamKey, !key.isEmpty else {
            return destination.url
        }
        guard !hasStreamID else {
            throw StreamingServiceError.unsupportedDestination(
                """
                The SRT destination URL already carries a 'streamid' and a stream key was also given \
                (--key, --key-env, or --key-stdin). Supply the key one way, not both: either put the \
                whole 'streamid' in the URL, or pass it as the key with no 'streamid' in the URL.
                """
            )
        }
        let separator = base.contains("?") ? "&" : "?"
        guard let composed = URL(string: "\(base)\(separator)streamid=\(key)") else {
            throw StreamingServiceError.unsupportedDestination(
                "The stream key could not be composed into the SRT destination URL — it must be URL-safe."
            )
        }
        return composed
    }

    /// The `streamid` value already present in an SRT URL string, if any —
    /// found by the same raw query split HaishinKit uses (no
    /// percent-decoding), so the check matches how the value is later read.
    static func existingStreamID(in urlString: String) -> String? {
        guard let queryStart = urlString.firstIndex(of: "?") else { return nil }
        let query = urlString[urlString.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "streamid" {
                return String(parts[1])
            }
        }
        return nil
    }

    /// A rejection reason safe to surface: built from the SRT connect error
    /// and the destination host, never from the composed URL (which holds
    /// the `streamid` secret).
    static func rejectionReason(for error: any Error, destination: Destination) -> String {
        let host = destination.url.host() ?? "the destination"
        switch error {
        case SRTConnection.Error.failedToConnect(let reason):
            return "The destination '\(host)' rejected the SRT connection (\(reason)) — check the stream key."
        case SRTConnection.Error.unsupportedUri:
            return "The SRT destination URL '\(host)' is not a valid SRT endpoint."
        default:
            return "The destination '\(host)' could not be reached or rejected the SRT handshake."
        }
    }

    /// The program's track topology as SRT expected medias, from the
    /// configuration's declared sides — the MPEG-TS muxer's up-front track
    /// declaration.
    static func expectedMedias(for configuration: StreamConfiguration) -> Set<AVMediaType> {
        var medias: Set<AVMediaType> = []
        if configuration.includesVideo { medias.insert(.video) }
        if configuration.includesAudio { medias.insert(.audio) }
        return medias
    }
}
