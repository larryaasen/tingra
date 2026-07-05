//
//  StreamTestSupport.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import TingraPlugInKit

/// A deterministic clock for tests, per CLOCK.md's substitution rule: the
/// tick stream yields exactly the scripted times to every consumer, then
/// finishes (or stays open) — no hardware, no wall clock waiting.
struct SyntheticClock: EngineClock {
    /// The times every tick stream yields, in order.
    let tickTimes: [CMTime]

    /// When true, tick streams never finish after the scripted times,
    /// standing in for a live clock.
    let staysOpen: Bool

    /// The time ``now`` reports.
    let currentTime: CMTime

    /// Creates a clock that yields `tickTimes` then finishes (or stays
    /// open), reporting `now` as the current time.
    init(now: CMTime = .zero, tickTimes: [CMTime] = [], staysOpen: Bool = false) {
        self.currentTime = now
        self.tickTimes = tickTimes
        self.staysOpen = staysOpen
    }

    /// The fixed current time.
    var now: CMTime { currentTime }

    /// Yields the scripted times regardless of the requested duration; the
    /// component under test decides the cadence, the test the timeline.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { continuation in
            for time in tickTimes {
                continuation.yield(time)
            }
            if !staysOpen {
                continuation.finish()
            }
        }
    }
}

/// A manually driven clock: ``advance(to:)`` broadcasts one tick to every
/// live tick stream, so a test controls exactly when the component under
/// test ticks.
final class ManualClock: EngineClock, Sendable {
    /// The live tick subscriptions.
    private let continuations = Mutex<[UUID: AsyncStream<CMTime>.Continuation]>([:])

    /// The time ``now`` reports, moved by ``advance(to:)``.
    private let currentTime = Mutex<CMTime>(.zero)

    /// Creates a clock at time zero.
    init() {}

    /// The most recently advanced-to time.
    var now: CMTime { currentTime.withLock { $0 } }

    /// A stream fed only by ``advance(to:)``.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { continuation in
            let id = UUID()
            continuations.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.continuations.withLock { $0[id] = nil }
            }
        }
    }

    /// Moves the clock and broadcasts the tick.
    func advance(to time: CMTime) {
        currentTime.withLock { $0 = time }
        let live = continuations.withLock { Array($0.values) }
        for continuation in live {
            continuation.yield(time)
        }
    }

    /// Finishes every live tick stream (the clock "stopping").
    func finishTicks() {
        let live = continuations.withLock { store in
            let values = Array(store.values)
            store.removeAll()
            return values
        }
        for continuation in live {
            continuation.finish()
        }
    }
}

/// A scripted input: yields the given frames and audio buffers when
/// started, then leaves the streams open until ``stop()``.
final class StubInput: Input, Sendable {
    /// The input's identifier.
    let id: InputID

    /// The input's name.
    let name: String

    /// The input's kind.
    let kind: InputKind

    /// The frames the video stream yields.
    private let scriptedFrames: [CapturedFrame]

    /// The audio buffers the audio stream yields.
    private let scriptedAudio: [CapturedAudio]

    /// The live continuations, finished by ``stop()``.
    private let frameContinuations = Mutex<[UUID: AsyncStream<CapturedFrame>.Continuation]>([:])

    /// The live audio continuations, finished by ``stop()``.
    private let audioContinuations = Mutex<[UUID: AsyncStream<CapturedAudio>.Continuation]>([:])

    /// Whether ``start()`` has been called.
    private let started = Mutex(false)

    /// Creates a stub yielding the given media.
    init(
        id: String,
        name: String,
        kind: InputKind,
        frames: [CapturedFrame] = [],
        audio: [CapturedAudio] = []
    ) {
        self.id = InputID(rawValue: id)
        self.name = name
        self.kind = kind
        self.scriptedFrames = frames
        self.scriptedAudio = audio
    }

    /// Whether the input was started.
    var wasStarted: Bool { started.withLock { $0 } }

    /// Records the start.
    func start() async throws {
        started.withLock { $0 = true }
    }

    /// Yields the scripted frames, then stays open until ``stop()``.
    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { continuation in
            let id = UUID()
            frameContinuations.withLock { $0[id] = continuation }
            for frame in scriptedFrames {
                continuation.yield(frame)
            }
            continuation.onTermination = { [weak self] _ in
                self?.frameContinuations.withLock { $0[id] = nil }
            }
        }
    }

    /// Yields the scripted audio, then stays open until ``stop()``.
    func audio() -> AsyncStream<CapturedAudio> {
        AsyncStream { continuation in
            let id = UUID()
            audioContinuations.withLock { $0[id] = continuation }
            for buffer in scriptedAudio {
                continuation.yield(buffer)
            }
            continuation.onTermination = { [weak self] _ in
                self?.audioContinuations.withLock { $0[id] = nil }
            }
        }
    }

    /// Finishes every live stream.
    func stop() async {
        let frames = frameContinuations.withLock { store in
            let values = Array(store.values)
            store.removeAll()
            return values
        }
        for continuation in frames {
            continuation.finish()
        }
        let audio = audioContinuations.withLock { store in
            let values = Array(store.values)
            store.removeAll()
            return values
        }
        for continuation in audio {
            continuation.finish()
        }
    }
}

/// A recording streaming service: captures every call, lets tests inject
/// connection losses and start failures — the mock behind the
/// `StreamingService` seam.
final class MockStreamingService: StreamingService, Sendable {
    /// One recorded start: where the session connected to.
    struct RecordedStart: Sendable {
        /// The destination URL string.
        let url: String

        /// Whether a stream key was present (never the value).
        let hadKey: Bool
    }

    /// The recorded protected state.
    private struct State: Sendable {
        /// Every start, in order.
        var starts: [RecordedStart] = []

        /// The session-timeline PTS of every video frame sent.
        var videoTimes: [CMTime] = []

        /// The session-timeline PTS of every audio buffer sent.
        var audioTimes: [CMTime] = []

        /// How many times ``stop()`` was called.
        var stops = 0

        /// Errors the next starts throw, consumed front-first.
        var startErrors: [StreamingServiceError] = []
    }

    /// The mock's state.
    private let state = Mutex(State())

    /// The events stream handed to the session.
    private let eventStream: AsyncStream<StreamingServiceEvent>

    /// Feeds ``eventStream``; tests emit losses through it.
    private let eventContinuation: AsyncStream<StreamingServiceEvent>.Continuation

    /// The statistics snapshot ``statistics()`` returns.
    let fixedStatistics: StreamingStatistics

    /// Creates a mock with the given statistics snapshot.
    init(statistics: StreamingStatistics = StreamingStatistics(bytesSent: 0, bytesPerSecond: 0, framesPerSecond: 0)) {
        self.fixedStatistics = statistics
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: StreamingServiceEvent.self)
    }

    /// The service's events, fed by ``reportConnectionLost(reason:)``.
    var events: AsyncStream<StreamingServiceEvent> { eventStream }

    /// Records the start, throwing the next queued start error if any.
    func start(to destination: Destination) async throws {
        let error = state.withLock { state -> StreamingServiceError? in
            if state.startErrors.isEmpty {
                state.starts.append(
                    RecordedStart(
                        url: destination.url.absoluteString,
                        hadKey: destination.streamKey != nil
                    )
                )
                return nil
            }
            return state.startErrors.removeFirst()
        }
        if let error {
            throw error
        }
    }

    /// Records the frame's PTS.
    func send(video frame: CapturedFrame) async {
        state.withLock { $0.videoTimes.append(frame.presentationTime) }
    }

    /// Records the buffer's PTS.
    func send(audio buffer: CapturedAudio) async {
        state.withLock { $0.audioTimes.append(buffer.presentationTime) }
    }

    /// Returns the fixed snapshot.
    func statistics() async -> StreamingStatistics {
        fixedStatistics
    }

    /// Records the stop and finishes the events stream.
    func stop() async {
        state.withLock { $0.stops += 1 }
        eventContinuation.finish()
    }

    /// Emits a connection loss to the session.
    func reportConnectionLost(reason: String) {
        eventContinuation.yield(.connectionLost(reason: reason))
    }

    /// Queues errors for the next ``start(to:)`` calls (reconnect attempts).
    func failNextStarts(with errors: [StreamingServiceError]) {
        state.withLock { $0.startErrors.append(contentsOf: errors) }
    }

    /// Every recorded start.
    var starts: [RecordedStart] { state.withLock { $0.starts } }

    /// The PTS of every video frame sent.
    var videoTimes: [CMTime] { state.withLock { $0.videoTimes } }

    /// The PTS of every audio buffer sent.
    var audioTimes: [CMTime] { state.withLock { $0.audioTimes } }

    /// How many times the service was stopped.
    var stops: Int { state.withLock { $0.stops } }
}

/// Polls a condition until it holds or the deadline passes — the bounded
/// wait tests use where task scheduling order is not deterministic.
/// Returns whether the condition held.
func eventually(
    within seconds: Double = 2,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Creates a small IOSurface-backed pixel buffer for pacing tests.
func makeTestPixelBuffer() -> CVPixelBuffer? {
    var bufferOut: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()] as CFDictionary,
        &bufferOut
    )
    return bufferOut
}

/// Creates a mono float32 LPCM audio buffer with the given PTS for
/// session-timeline tests.
func makeTestAudio(pts: CMTime, samples: Int = 256, sampleRate: Int = 48_000) -> CapturedAudio? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: Float64(sampleRate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var formatOut: CMAudioFormatDescription?
    guard
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatOut
        ) == noErr,
        let format = formatOut
    else { return nil }
    let dataLength = samples * MemoryLayout<Float32>.size
    var blockOut: CMBlockBuffer?
    guard
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockOut
        ) == noErr,
        let block = blockOut
    else { return nil }
    var sampleOut: CMSampleBuffer?
    guard
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: samples,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleOut
        ) == noErr,
        let sample = sampleOut
    else { return nil }
    return CapturedAudio(sampleBuffer: sample)
}
