//
//  MCPTestSupport.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Synchronization
import TingraEventBus
import TingraPlugInKit

@testable import TingraMCP

/// A deterministic clock whose tick streams finish immediately, so a stream
/// session under test never busy-loops on real time (no stats ticks, no
/// paced frames) — the coordinator tests exercise start/status/stop, not
/// pacing.
struct FinishingClock: EngineClock {
    /// Always zero.
    var now: CMTime { .zero }

    /// A tick stream that finishes at once.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { $0.finish() }
    }
}

/// A scripted input that starts cleanly and produces no media — enough for
/// the coordinator to build and run a session.
final class StubInput: Input, Sendable {
    let id: InputID
    let name: String
    let kind: InputKind

    /// Whether ``start()`` was called.
    private let started = Mutex(false)

    /// Creates a stub input.
    init(id: String, name: String, kind: InputKind) {
        self.id = InputID(rawValue: id)
        self.name = name
        self.kind = kind
    }

    /// Whether the input was started.
    var wasStarted: Bool { started.withLock { $0 } }

    func start() async throws { started.withLock { $0 = true } }

    func stop() async {}
}

/// A streaming service that records calls and can be told to reject its start
/// — the mock behind the seam for coordinator tests.
final class MockStreamingService: StreamingService, Sendable {
    /// The error the next ``start(to:)`` throws, if set.
    private let startError: Mutex<StreamingServiceError?>

    /// How many times ``stop()`` was called.
    private let stopCount = Mutex(0)

    /// The events stream (a loss can be injected through it).
    private let eventStream: AsyncStream<StreamingServiceEvent>

    /// Feeds ``eventStream``.
    private let eventContinuation: AsyncStream<StreamingServiceEvent>.Continuation

    /// Creates a mock, optionally rejecting the first start.
    init(startError: StreamingServiceError? = nil) {
        self.startError = Mutex(startError)
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: StreamingServiceEvent.self)
    }

    var events: AsyncStream<StreamingServiceEvent> { eventStream }

    func start(to destination: Destination) async throws {
        if let error = startError.withLock({ value -> StreamingServiceError? in
            defer { value = nil }
            return value
        }) {
            throw error
        }
    }

    func send(video frame: CapturedFrame) async {}

    func send(audio buffer: CapturedAudio) async {}

    func statistics() async -> StreamingStatistics {
        StreamingStatistics(bytesSent: 0, bytesPerSecond: 0, framesPerSecond: 0)
    }

    func stop() async {
        stopCount.withLock { $0 += 1 }
        eventContinuation.finish()
    }

    /// How many times the service was stopped.
    var stops: Int { stopCount.withLock { $0 } }
}

/// A provider that hands out a fixed mock service — so a test can inspect the
/// same service the coordinator drove.
struct MockProvider: StreamingServiceProvider {
    let id = OutputID(rawValue: "mock")
    let name = "Mock Output"
    let schemes = ["rtmp", "rtmps"]

    /// The service every stream gets.
    let service: MockStreamingService

    func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService {
        service
    }
}

/// Polls a condition until it holds or the deadline passes — the bounded
/// wait tests use where task scheduling order is not deterministic.
func poll(within seconds: Double = 2, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Decodes one written line into a ``JSONValue`` for inspection.
func decodeLine(_ line: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

extension Data {
    /// The data as a UTF-8 string, for readable assertions.
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}

extension String {
    /// The string as UTF-8 data, for enqueuing onto a transport.
    var utf8Data: Data { Data(utf8) }
}
