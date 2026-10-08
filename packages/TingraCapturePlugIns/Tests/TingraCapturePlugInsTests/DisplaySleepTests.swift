//
//  DisplaySleepTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraCapturePlugIns

/// The display the sleep tests capture.
private let sleepyDisplay = DisplayDevice(
    uniqueID: "84D18885-B835-4AE9-A5A4-F1394DD4E56A",
    name: "Display 2",
    pixelWidth: 2560,
    pixelHeight: 1440
)

/// A scripted capture seam: records every capture it starts and stops, can
/// refuse or reject a start, and lets a test end a capture or deliver a frame
/// through it as ScreenCaptureKit would.
private final class FakeCaptures: Sendable {
    /// What one started capture was handed.
    private struct Started: Sendable {
        /// Where its frames go.
        let deliver: @Sendable (CapturedFrame) -> Void

        /// What it calls when it ends on its own.
        let ended: @Sendable (DisplayCaptureEnd) -> Void
    }

    /// Every capture started, in order; a capture's index is its position.
    private let started = Mutex<[Started]>([])

    /// The start attempts, counting refused ones, that throw.
    private let refusals: Set<Int>

    /// The start attempts that throw as ScreenCaptureKit rejecting the
    /// configuration, the display still being connected.
    private let rejections: Set<Int>

    /// How many starts have been attempted.
    private let attempts = Mutex(0)

    /// The indices of the captures stopped, in order.
    private let stoppedIndices = Mutex<[Int]>([])

    /// Each stop as it happens, so a test can wait for one.
    let stops: AsyncStream<Int>

    /// Feeds ``stops``.
    private let stopContinuation: AsyncStream<Int>.Continuation

    /// Creates the seam.
    ///
    /// - Parameters:
    ///   - refusals: The start attempts (0 is the first) that throw as the
    ///     display having disconnected.
    ///   - rejections: The start attempts that throw as a rejected
    ///     configuration.
    init(refusals: Set<Int> = [], rejections: Set<Int> = []) {
        self.refusals = refusals
        self.rejections = rejections
        (stops, stopContinuation) = AsyncStream.makeStream(of: Int.self)
    }

    /// The capture seam the input is handed.
    var starter: DisplayCaptureStarter {
        { [self] _, id, deliver, ended in
            let attempt = attempts.withLock { count in
                defer { count += 1 }
                return count
            }
            if refusals.contains(attempt) {
                throw CaptureInputError.deviceUnavailable(id)
            }
            if rejections.contains(attempt) {
                throw CaptureInputError.configurationRejected(id, "The stream could not start")
            }
            let index = started.withLock { started in
                started.append(Started(deliver: deliver, ended: ended))
                return started.count - 1
            }
            return FakeCapture(index: index, owner: self)
        }
    }

    /// How many captures have started.
    var startCount: Int { started.withLock { $0.count } }

    /// The indices of the captures stopped, in order.
    var stopped: [Int] { stoppedIndices.withLock { $0 } }

    /// Ends a capture as ScreenCaptureKit would.
    ///
    /// - Parameters:
    ///   - index: The capture.
    ///   - end: Why it ended.
    func end(capture index: Int, _ end: DisplayCaptureEnd) {
        started.withLock { $0[index] }.ended(end)
    }

    /// Delivers a frame through a capture.
    ///
    /// - Parameters:
    ///   - frame: The frame.
    ///   - index: The capture.
    func deliver(_ frame: CapturedFrame, through index: Int) {
        started.withLock { $0[index] }.deliver(frame)
    }

    /// Records a stop.
    ///
    /// - Parameter index: The capture stopped.
    fileprivate func markStopped(_ index: Int) {
        stoppedIndices.withLock { $0.append(index) }
        stopContinuation.yield(index)
    }
}

/// One fake capture, reporting its stop to the seam that started it.
private struct FakeCapture: DisplayCapture {
    /// Its position among the captures started.
    let index: Int

    /// The seam that started it.
    let owner: FakeCaptures

    func stop() async {
        owner.markStopped(index)
    }
}

/// Counts the input's power subscriptions — a class, because the count is
/// shared between the harness and the subscription closure.
private final class SubscriptionCounter: Sendable {
    /// The count.
    private let count = Mutex(0)

    /// Counts one subscription.
    func increment() {
        count.withLock { $0 += 1 }
    }

    /// The subscriptions so far.
    var value: Int { count.withLock { $0 } }
}

/// A display input over the fakes, its bus, and its scripted power events.
private struct SleepHarness {
    /// The input under test.
    let input: DisplayInput

    /// The captures it starts.
    let captures: FakeCaptures

    /// The bus it reports on.
    let eventBus: EventBus

    /// The bus's events, read in order.
    var events: AsyncStream<EventBusEvent>.Iterator

    /// Scripts the displays sleeping and waking.
    let power: AsyncStream<DisplayPowerEvent>.Continuation

    /// Fires when the input's power subscription ends.
    let powerEnded: AsyncStream<Void>

    /// How many times the input subscribed to power events.
    let subscriptions: SubscriptionCounter

    /// Builds the harness.
    ///
    /// - Parameters:
    ///   - refusals: The start attempts that throw as the display having
    ///     disconnected.
    ///   - rejections: The start attempts that throw as a rejected
    ///     configuration.
    init(refusals: Set<Int> = [], rejections: Set<Int> = []) {
        let captures = FakeCaptures(refusals: refusals, rejections: rejections)
        let eventBus = EventBus()
        let (powerEvents, power) = AsyncStream.makeStream(of: DisplayPowerEvent.self)
        let (powerEnded, powerEndedContinuation) = AsyncStream.makeStream(of: Void.self)
        power.onTermination = { _ in powerEndedContinuation.yield() }
        let subscriptions = SubscriptionCounter()
        self.captures = captures
        self.eventBus = eventBus
        self.events = eventBus.events().makeAsyncIterator()
        self.power = power
        self.powerEnded = powerEnded
        self.subscriptions = subscriptions
        self.input = DisplayInput(
            display: sleepyDisplay,
            eventBus: eventBus,
            requestAuthorization: { true },
            powerEvents: {
                subscriptions.increment()
                return powerEvents
            },
            startCapture: captures.starter
        )
    }

    /// The next event the input reports.
    mutating func nextEvent() async -> EventBusEvent? {
        await events.next()
    }
}

/// Creates a small frame for delivery tests.
private func makeFrame() throws -> CapturedFrame {
    var bufferOut: CVPixelBuffer?
    try #require(
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &bufferOut)
            == kCVReturnSuccess
    )
    return CapturedFrame(pixelBuffer: try #require(bufferOut), presentationTime: .zero)
}

@Suite("Display capture across display sleep")
struct DisplaySleepTests {
    @Test("a display sleep stops the capture and reports input.interrupted as a normal event")
    func sleepInterrupts() async throws {
        var harness = SleepHarness()
        try await harness.input.start()
        harness.power.yield(.slept)

        let event = try #require(await harness.nextEvent())
        #expect(event.name == "input.interrupted")
        #expect(event.group == .event)
        #expect(event.params?["reason"] == .string("displaySleep"))
        #expect(event.params?["id"] == .string(sleepyDisplay.uniqueID))
        #expect(event.params?["name"] == .string("Display 2"))
        #expect(harness.captures.stopped == [0])
        await harness.input.stop()
    }

    @Test("a wake starts a fresh capture and reports input.resumed")
    func wakeResumes() async throws {
        var harness = SleepHarness()
        try await harness.input.start()
        harness.power.yield(.slept)
        harness.power.yield(.woke)

        #expect(await harness.nextEvent()?.name == "input.interrupted")
        let resumed = try #require(await harness.nextEvent())
        #expect(resumed.name == "input.resumed")
        #expect(resumed.group == .event)
        #expect(resumed.params?["id"] == .string(sleepyDisplay.uniqueID))
        #expect(harness.captures.startCount == 2)
        await harness.input.stop()
    }

    @Test("a capture ScreenCaptureKit stops reports streamStopped, and the next wake restarts it")
    func streamStopThenWake() async throws {
        var harness = SleepHarness()
        try await harness.input.start()
        harness.captures.end(capture: 0, .stopped)

        let interrupted = try #require(await harness.nextEvent())
        #expect(interrupted.name == "input.interrupted")
        #expect(interrupted.params?["reason"] == .string("streamStopped"))
        #expect(interrupted.params?["error"] == nil)

        // The display sleep notification that follows the stop finds nothing
        // running, so it reports nothing more; the wake restarts.
        harness.power.yield(.slept)
        harness.power.yield(.woke)
        #expect(await harness.nextEvent()?.name == "input.resumed")
        #expect(harness.captures.startCount == 2)
        await harness.input.stop()
    }

    @Test("a stream that stops with an error reports streamFailed with ScreenCaptureKit's description")
    func streamFailure() async throws {
        var harness = SleepHarness()
        try await harness.input.start()
        harness.captures.end(capture: 0, .failed("The display is unavailable"))

        let interrupted = try #require(await harness.nextEvent())
        #expect(interrupted.name == "input.interrupted")
        #expect(interrupted.group == .event)
        #expect(interrupted.params?["reason"] == .string("streamFailed"))
        #expect(interrupted.params?["error"] == .string("The display is unavailable"))
        await harness.input.stop()
    }

    @Test("a wake with the capture still running restarts it anyway, stopping the old one first")
    func wakeRestartsARunningCapture() async throws {
        var harness = SleepHarness()
        try await harness.input.start()
        harness.power.yield(.woke)

        #expect(await harness.nextEvent()?.name == "input.resumed")
        #expect(harness.captures.stopped == [0])
        #expect(harness.captures.startCount == 2)
        await harness.input.stop()
    }

    @Test("a late end from a capture already replaced is ignored")
    func lateEndIgnored() async throws {
        var harness = SleepHarness()
        try await harness.input.start()
        harness.power.yield(.woke)
        #expect(await harness.nextEvent()?.name == "input.resumed")

        // Capture 0 was replaced; its report must not interrupt capture 1.
        // Capture 1's own end, sent after it, is the next event — which
        // proves capture 0's produced none.
        harness.captures.end(capture: 0, .stopped)
        harness.captures.end(capture: 1, .failed("gone"))
        let next = try #require(await harness.nextEvent())
        #expect(next.name == "input.interrupted")
        #expect(next.params?["error"] == .string("gone"))
        await harness.input.stop()
    }

    @Test("a restart that cannot start reports input.resume as an error, and the next wake tries again")
    func failedResumeRetriesAtNextWake() async throws {
        var harness = SleepHarness(rejections: [1])
        try await harness.input.start()
        harness.power.yield(.slept)
        harness.power.yield(.woke)

        #expect(await harness.nextEvent()?.name == "input.interrupted")
        let failed = try #require(await harness.nextEvent())
        #expect(failed.name == "input.resume")
        #expect(failed.group == .error)
        #expect(failed.params?["id"] == .string(sleepyDisplay.uniqueID))

        harness.power.yield(.woke)
        #expect(await harness.nextEvent()?.name == "input.resumed")
        #expect(harness.captures.startCount == 2)
        await harness.input.stop()
    }

    @Test("a restart that finds the display disconnected reports nothing, and the next wake tries again")
    func resumeOfADisconnectedDisplayIsNotAnError() async throws {
        var harness = SleepHarness(refusals: [1])
        try await harness.input.start()
        harness.power.yield(.slept)
        harness.power.yield(.woke)
        harness.power.yield(.woke)

        // The refused restart sits between these two events and reported
        // neither an error nor anything else: the disconnection is the
        // plug-in's `device.disconnected` to report.
        #expect(await harness.nextEvent()?.name == "input.interrupted")
        let resumed = try #require(await harness.nextEvent())
        #expect(resumed.name == "input.resumed")
        #expect(resumed.group == .event)
        #expect(harness.captures.startCount == 2)
        await harness.input.stop()
    }

    @Test("frames keep reaching the same consumer from the restarted capture")
    func framesContinueAcrossRestart() async throws {
        var harness = SleepHarness()
        try await harness.input.start()
        var frames = harness.input.frames().makeAsyncIterator()
        harness.power.yield(.slept)
        harness.power.yield(.woke)
        #expect(await harness.nextEvent()?.name == "input.interrupted")
        #expect(await harness.nextEvent()?.name == "input.resumed")

        harness.captures.deliver(try makeFrame(), through: 1)
        #expect(await frames.next() != nil)
        await harness.input.stop()
    }

    @Test("stopping the input stops its capture and ends its power subscription")
    func stopEndsTheSession() async throws {
        let harness = SleepHarness()
        try await harness.input.start()
        var stops = harness.captures.stops.makeAsyncIterator()
        var powerEnded = harness.powerEnded.makeAsyncIterator()

        await harness.input.stop()
        #expect(await stops.next() == 0)
        await powerEnded.next()
        #expect(harness.captures.stopped == [0])
        #expect(harness.captures.startCount == 1)
    }

    @Test("a start that cannot begin throws and never subscribes to power events")
    func failedStartSubscribesToNothing() async {
        let harness = SleepHarness(refusals: [0])
        await #expect(throws: CaptureInputError.deviceUnavailable(harness.input.id)) {
            try await harness.input.start()
        }
        #expect(harness.subscriptions.value == 0)
    }

    @Test("capture ends name their reason for the event")
    func captureEndReasons() {
        #expect(DisplayCaptureEnd.stopped.reason == "streamStopped")
        #expect(DisplayCaptureEnd.stopped.message == nil)
        #expect(DisplayCaptureEnd.failed("x").reason == "streamFailed")
        #expect(DisplayCaptureEnd.failed("x").message == "x")
        #expect(DisplayCaptureEnd.stopped != .failed("x"))
        #expect(DisplayCaptureEnd.failed("x") == .failed("x"))
    }
}
