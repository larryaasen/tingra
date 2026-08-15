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
import TingraHost
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

    /// The destination the service was last started to, so a test can assert
    /// which URL and stream key a leg actually published with — the only way
    /// to see that a saved destination resolved to the right pair.
    private let started = Mutex<Destination?>(nil)

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
        started.withLock { $0 = destination }
    }

    /// The destination the service was last started to, or nil before any
    /// start.
    var startedDestination: Destination? { started.withLock { $0 } }

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

    /// Reports a lost connection, the shape a destination takes when it
    /// accepts the publish and then drops it. With reconnect disabled the
    /// session ends on this, which is one of the teardown paths that is not
    /// an explicit stop.
    func reportConnectionLoss(reason: String = "injected by a test") {
        eventContinuation.yield(.connectionLost(reason: reason))
    }
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

/// A recording service that records calls and can be told to refuse its
/// start — the mock behind the recording seam for coordinator tests, so no
/// test touches a disk or an encoder.
final class MockRecordingService: RecordingService, Sendable {
    /// The error the next ``start(to:)`` throws, if set.
    private let startError: Mutex<RecordingServiceError?>

    /// The file the last ``start(to:)`` opened, if any.
    private let startedFile: Mutex<RecordingFile?>

    /// How many times ``stop()`` was called.
    private let stopCount = Mutex(0)

    /// The events stream (a write failure can be injected through it).
    private let eventStream: AsyncStream<RecordingServiceEvent>

    /// Feeds ``eventStream``.
    private let eventContinuation: AsyncStream<RecordingServiceEvent>.Continuation

    /// Creates a mock, optionally refusing the first start.
    init(startError: RecordingServiceError? = nil) {
        self.startError = Mutex(startError)
        self.startedFile = Mutex(nil)
        (self.eventStream, self.eventContinuation) = AsyncStream.makeStream(of: RecordingServiceEvent.self)
    }

    var events: AsyncStream<RecordingServiceEvent> { eventStream }

    func start(to file: RecordingFile) async throws {
        if let error = startError.withLock({ value -> RecordingServiceError? in
            defer { value = nil }
            return value
        }) {
            throw error
        }
        startedFile.withLock { $0 = file }
    }

    func send(video frame: CapturedFrame) async {}

    func send(audio buffer: CapturedAudio) async {}

    func stop() async {
        stopCount.withLock { $0 += 1 }
        eventContinuation.finish()
    }

    /// The file the service was started to, or nil if it never opened.
    var openedFile: RecordingFile? { startedFile.withLock { $0 } }

    /// How many times the service was stopped.
    var stops: Int { stopCount.withLock { $0 } }

    /// Reports a terminal write failure (a full disk), the recording's one
    /// mid-session event.
    func reportWriteFailure(reason: String = "injected by a test") {
        eventContinuation.yield(.failed(reason: reason))
    }
}

/// A provider that hands out a fixed mock recording service — so a test can
/// inspect the same service the coordinator drove.
struct MockRecordingProvider: RecordingServiceProvider {
    let id = OutputID(rawValue: "mock-recording")
    let name = "Mock Recording"
    let fileExtensions = ["mov", "mp4"]

    /// The service every recording gets.
    let service: MockRecordingService

    func makeRecordingService(configuration: StreamConfiguration) -> any RecordingService {
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

/// The async-condition form of ``poll(within:_:)`` — how a test awaits an
/// event emitted on the bus settling into an attached actor sink.
func eventually(within seconds: Double = 2, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
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

/// An in-memory ``SecureStorage`` for the destination tests, so no test
/// touches the real Keychain (no unlocked login keychain, no prompt on a CI
/// runner). It mirrors the double in the TingraHost test target — test
/// targets cannot share code, so the two are deliberate twins rather than a
/// duplicated helper.
///
/// ``readFailure`` makes every read throw, which is the only way to reach the
/// unsigned-development-build path: a real process either has the entitlement
/// or does not, and a test cannot un-sign itself.
final class InMemorySecureStorage: SecureStorage {
    /// The stored secrets, keyed by account.
    private let secrets = Mutex<[String: String]>([:])

    /// The error every read throws, or nil to read normally.
    private let readFailure: SecureStorageError?

    /// Creates a double.
    ///
    /// - Parameter readFailure: An error every read throws, or nil.
    init(readFailure: SecureStorageError? = nil) {
        self.readFailure = readFailure
    }

    func setSecret(_ secret: String, forAccount account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    func secret(forAccount account: String) throws -> String? {
        if let readFailure { throw readFailure }
        return secrets.withLock { $0[account] }
    }

    func removeSecret(forAccount account: String) throws {
        secrets.withLock { $0[account] = nil }
    }
}

/// A ``DestinationStore`` over a temporary directory, seeded with the
/// destinations a test needs — so the tool surface is exercised against a real
/// document and never the operator's own (DESTINATIONS.md: the store is
/// operator state).
final class DestinationFixture {
    /// The temporary directory the document lives in, removed at deinit.
    private let directory: URL

    /// The store under test.
    let store: DestinationStore

    /// Seeds a store.
    ///
    /// - Parameters:
    ///   - destinations: The destinations to file, in order.
    ///   - keys: The stream key to file for each destination id, if any.
    ///   - readFailure: An error the secret store's reads throw, standing in
    ///     for an unsigned development build.
    ///   - eventBus: The bus the store's change events go out on.
    init(
        destinations: [StoredDestination] = [],
        keys: [String: String] = [:],
        readFailure: SecureStorageError? = nil,
        eventBus: EventBus = EventBus()
    ) async throws {
        directory = URL.temporaryDirectory.appending(path: "tingra-mcp-destinations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let secureStorage = InMemorySecureStorage(readFailure: readFailure)
        store = DestinationStore(directory: directory, secureStorage: secureStorage, eventBus: eventBus)
        for destination in destinations {
            try await store.add(destination)
            if let key = keys[destination.id.rawValue] {
                // Filed directly, so a store whose reads fail can still be
                // seeded — `setKey` writes, and only reads are faulted.
                try secureStorage.setSecret(key, forAccount: DestinationStore.secureStorageAccount(for: destination.id))
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A saved destination for the tool tests.
///
/// - Parameters:
///   - id: The stable id.
///   - name: The operator's label.
///   - url: The destination URL.
/// - Returns: The destination.
func savedDestination(
    id: String = "dest-twitch",
    name: String = "Twitch",
    url: String = "rtmp://localhost/live"
) -> StoredDestination {
    StoredDestination(id: DestinationID(rawValue: id), name: name, url: URL(string: url) ?? URL.temporaryDirectory)
}
