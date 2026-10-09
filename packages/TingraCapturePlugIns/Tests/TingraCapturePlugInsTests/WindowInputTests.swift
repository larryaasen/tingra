//
//  WindowInputTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Synchronization
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraCapturePlugIns

/// The window the tests capture.
private let deck = WindowTarget(bundleIdentifier: "com.apple.Keynote", applicationName: "Keynote", title: "Launch Deck")

/// The identifier the tests' input reports.
private let deckInputID = InputID(rawValue: "window-1")

/// Makes a window record.
///
/// - Parameters:
///   - id: The window's identifier.
///   - bundle: The owning application's bundle identifier.
///   - application: The owning application's name.
///   - title: The window's title.
///   - isOnScreen: Whether it is on screen.
/// - Returns: The record.
private func window(
    _ id: UInt32,
    bundle: String = "com.apple.Keynote",
    application: String = "Keynote",
    title: String,
    isOnScreen: Bool = true
) -> CaptureWindow {
    CaptureWindow(
        id: id,
        target: WindowTarget(bundleIdentifier: bundle, applicationName: application, title: title),
        width: 1280,
        height: 720,
        isOnScreen: isOnScreen
    )
}

@Suite("Window targets and matching")
struct WindowMatchingTests {
    @Test("a target is named by its application, then its title")
    func targetName() {
        #expect(deck.name == "Keynote — Launch Deck")
    }

    @Test("a window titled as its application, or not at all, is named by the application alone")
    func targetNameWithoutADistinctTitle() {
        let same = WindowTarget(bundleIdentifier: "com.example.app", applicationName: "Example", title: "Example")
        let empty = WindowTarget(bundleIdentifier: "com.example.app", applicationName: "Example", title: "")
        #expect(same.name == "Example")
        #expect(empty.name == "Example")
    }

    @Test("targets compare equal only when application and title all match")
    func targetEquality() {
        let twin = WindowTarget(
            bundleIdentifier: "com.apple.Keynote", applicationName: "Keynote", title: "Launch Deck")
        let retitled = WindowTarget(bundleIdentifier: "com.apple.Keynote", applicationName: "Keynote", title: "Other")
        #expect(deck == twin)
        #expect(deck != retitled)
    }

    @Test("window records compare equal only when every field matches")
    func windowEquality() {
        #expect(window(7, title: "Launch Deck") == window(7, title: "Launch Deck"))
        #expect(window(7, title: "Launch Deck") != window(8, title: "Launch Deck"))
        #expect(window(7, title: "Launch Deck") != window(7, title: "Launch Deck", isOnScreen: false))
    }

    @Test("the window last captured is found by its identifier even after it was retitled")
    func resolvesByLastIdentifier() {
        let windows = [window(7, title: "Renamed Since"), window(9, title: "Launch Deck")]
        #expect(WindowMatching.resolve(deck, lastWindowID: 7, among: windows)?.id == 7)
    }

    @Test("an identifier now belonging to another application's window is not trusted")
    func ignoresAnIdentifierOwnedByAnotherApplication() {
        let windows = [window(7, bundle: "com.apple.finder", application: "Finder", title: "Launch Deck")]
        #expect(WindowMatching.resolve(deck, lastWindowID: 7, among: windows) == nil)
    }

    @Test("with no identifier, the application's window with the saved title is found")
    func resolvesByTitle() {
        let windows = [
            window(3, bundle: "com.apple.finder", application: "Finder", title: "Launch Deck"),
            window(5, title: "Budget"),
            window(9, title: "Launch Deck"),
        ]
        #expect(WindowMatching.resolve(deck, lastWindowID: nil, among: windows)?.id == 9)
    }

    @Test("of several windows with the saved title, one on screen wins, then the oldest")
    func resolvesAmongSameTitles() {
        let offAndOn = [window(4, title: "Launch Deck", isOnScreen: false), window(9, title: "Launch Deck")]
        #expect(WindowMatching.resolve(deck, lastWindowID: nil, among: offAndOn)?.id == 9)
        let bothOn = [window(9, title: "Launch Deck"), window(4, title: "Launch Deck")]
        #expect(WindowMatching.resolve(deck, lastWindowID: nil, among: bothOn)?.id == 4)
    }

    @Test("a retitled window is found when it is the application's only window on screen")
    func resolvesTheOnlyWindowOnScreen() {
        let windows = [window(5, title: "Launch Deck v2"), window(6, title: "Inspector", isOnScreen: false)]
        #expect(WindowMatching.resolve(deck, lastWindowID: nil, among: windows)?.id == 5)
    }

    @Test("no window is named when the title is gone and the application shows several")
    func doesNotGuessAmongSeveral() {
        let windows = [window(5, title: "Budget"), window(6, title: "Roadmap")]
        #expect(WindowMatching.resolve(deck, lastWindowID: nil, among: windows) == nil)
    }

    @Test("no window is named when the application has none open")
    func resolvesNothingWithoutWindows() {
        let windows = [window(3, bundle: "com.apple.finder", application: "Finder", title: "Downloads")]
        #expect(WindowMatching.resolve(deck, lastWindowID: 3, among: windows) == nil)
        #expect(WindowMatching.resolve(deck, lastWindowID: nil, among: []) == nil)
    }

    @Test("the picker lists the windows on screen, by application and then title")
    func pickerOrder() {
        let windows = [
            window(1, title: "Roadmap"),
            window(2, bundle: "com.apple.finder", application: "Finder", title: "Downloads"),
            window(3, title: "Budget"),
            window(4, title: "Hidden Panel", isOnScreen: false),
            window(5, title: "Budget"),
        ]
        #expect(WindowMatching.pickerWindows(from: windows).map(\.id) == [2, 3, 5, 1])
    }
}

@Suite("Window pixel size")
struct WindowPixelSizeTests {
    @Test("a window's pixels are its points at the display's scale")
    func pixelsFromPoints() {
        let size = WindowPixelSize.pixels(pointSize: CGSize(width: 920, height: 436), scale: 2)
        #expect(size == WindowPixelSize(width: 1840, height: 872))
    }

    @Test("a frame the window fills at its own size reports that size")
    func nativeWhenUnscaled() {
        let size = WindowPixelSize.native(
            contentSize: CGSize(width: 920, height: 436), contentScale: 1, scaleFactor: 2)
        #expect(size == WindowPixelSize(width: 1840, height: 872))
    }

    @Test("a window scaled down into a smaller frame reports its own size, not the frame's")
    func nativeWhenScaledToFit() {
        // Measured: a 920 x 436 point window in a 1000 x 1000 frame.
        let size = WindowPixelSize.native(
            contentSize: CGSize(width: 499.99999046325684, height: 236.95651721954346),
            contentScale: 0.54347825050354,
            scaleFactor: 2
        )
        #expect(size == WindowPixelSize(width: 1840, height: 872))
    }

    @Test("a measurement that is not a size reports nothing")
    func rejectsNonSizes() {
        #expect(WindowPixelSize.pixels(pointSize: .zero, scale: 2) == nil)
        #expect(WindowPixelSize.pixels(pointSize: CGSize(width: 100, height: 100), scale: 0) == nil)
        #expect(WindowPixelSize.pixels(pointSize: CGSize(width: 100, height: 100), scale: .nan) == nil)
        #expect(
            WindowPixelSize.native(contentSize: CGSize(width: 100, height: 100), contentScale: 0, scaleFactor: 2)
                == nil)
    }

    @Test("a window dragged down to almost nothing is still a frame")
    func clampsToTheMinimumSide() {
        let size = WindowPixelSize.pixels(pointSize: CGSize(width: 0.2, height: 300), scale: 1)
        #expect(size == WindowPixelSize(width: WindowPixelSize.minimumSide, height: 300))
    }

    @Test("sizes compare equal only when both sides match")
    func equality() {
        #expect(WindowPixelSize(width: 10, height: 20) == WindowPixelSize(width: 10, height: 20))
        #expect(WindowPixelSize(width: 10, height: 20) != WindowPixelSize(width: 20, height: 10))
    }
}

/// A scripted window capture seam: records every capture it starts, stops,
/// and resizes, can find no window or reject a start, and lets a test end a
/// capture, deliver a frame, or report a new size through it as
/// ScreenCaptureKit would.
private final class FakeWindowCaptures: Sendable {
    /// What one started capture was handed.
    private struct Started: Sendable {
        /// The identifier the session asked for.
        let lastWindowID: UInt32?

        /// Where its frames go.
        let deliver: @Sendable (CapturedFrame) -> Void

        /// What it calls when it ends on its own.
        let ended: @Sendable (DisplayCaptureEnd) -> Void

        /// What it calls when its window changes size.
        let resized: @Sendable (WindowPixelSize) -> Void
    }

    /// Every capture started, in order; a capture's index is its position.
    private let started = Mutex<[Started]>([])

    /// The start attempts that find no window.
    private let absences: Set<Int>

    /// The start attempts that throw as a rejected configuration.
    private let rejections: Set<Int>

    /// How many starts have been attempted.
    private let attempts = Mutex(0)

    /// The indices of the captures stopped, in order.
    private let stoppedIndices = Mutex<[Int]>([])

    /// Each resize applied, as it happens, so a test can wait for one.
    let resizes: AsyncStream<WindowPixelSize>

    /// Feeds ``resizes``.
    private let resizeContinuation: AsyncStream<WindowPixelSize>.Continuation

    /// Creates the seam.
    ///
    /// - Parameters:
    ///   - absences: The start attempts (0 is the first) that find no
    ///     window.
    ///   - rejections: The start attempts that throw as a rejected
    ///     configuration.
    init(absences: Set<Int> = [], rejections: Set<Int> = []) {
        self.absences = absences
        self.rejections = rejections
        (resizes, resizeContinuation) = AsyncStream.makeStream(of: WindowPixelSize.self)
    }

    /// The capture seam the input is handed. Each capture is of window 40
    /// plus its index, so a test can see the identifier carried forward.
    var starter: WindowCaptureStarter {
        { [self] _, lastWindowID, id, deliver, ended, resized in
            let attempt = attempts.withLock { count in
                defer { count += 1 }
                return count
            }
            if absences.contains(attempt) {
                throw CaptureInputError.deviceUnavailable(id)
            }
            if rejections.contains(attempt) {
                throw CaptureInputError.configurationRejected(id, "The stream could not start")
            }
            let index = started.withLock { started in
                started.append(Started(lastWindowID: lastWindowID, deliver: deliver, ended: ended, resized: resized))
                return started.count - 1
            }
            return FakeWindowCapture(index: index, windowID: UInt32(40 + index), owner: self)
        }
    }

    /// How many captures have started.
    var startCount: Int { started.withLock { $0.count } }

    /// How many starts have been attempted, found or not.
    var attemptCount: Int { attempts.withLock { $0 } }

    /// The indices of the captures stopped, in order.
    var stopped: [Int] { stoppedIndices.withLock { $0 } }

    /// The identifier each started capture was asked to find.
    var requestedWindowIDs: [UInt32?] { started.withLock { $0.map(\.lastWindowID) } }

    /// Ends a capture as ScreenCaptureKit would.
    func end(capture index: Int, _ end: DisplayCaptureEnd) {
        started.withLock { $0[index] }.ended(end)
    }

    /// Delivers a frame through a capture.
    func deliver(_ frame: CapturedFrame, through index: Int) {
        started.withLock { $0[index] }.deliver(frame)
    }

    /// Reports a capture's window at a new size.
    func resize(capture index: Int, to size: WindowPixelSize) {
        started.withLock { $0[index] }.resized(size)
    }

    /// Records a stop.
    fileprivate func markStopped(_ index: Int) {
        stoppedIndices.withLock { $0.append(index) }
    }

    /// Records an applied resize.
    fileprivate func markResized(_ size: WindowPixelSize) {
        resizeContinuation.yield(size)
    }
}

/// One fake window capture, reporting its stop and resizes to its seam.
private struct FakeWindowCapture: WindowCapture {
    /// Its position among the captures started.
    let index: Int

    /// The window it captures.
    let windowID: UInt32

    /// The seam that started it.
    let owner: FakeWindowCaptures

    func stop() async {
        owner.markStopped(index)
    }

    func resize(to size: WindowPixelSize) async {
        owner.markResized(size)
    }
}

/// The scripted arrivals behind the harness's stream, handed over one at a
/// time as the input asks for them — so the harness can tell when the input
/// has taken one (``WindowHarness/arrivalPulls``).
private final class ArrivalQueue: Sendable {
    /// What is queued and who is waiting.
    private struct State {
        /// Arrivals scripted and not yet taken.
        var pending: [ApplicationArrival] = []

        /// The reader waiting for the next arrival, if one is.
        var waiter: CheckedContinuation<ApplicationArrival?, Never>?
    }

    /// The queue's state.
    private let state = Mutex(State())

    /// Scripts an arrival.
    func push(_ arrival: ApplicationArrival) {
        let waiter = state.withLock { state -> CheckedContinuation<ApplicationArrival?, Never>? in
            guard let waiter = state.waiter else {
                state.pending.append(arrival)
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: arrival)
    }

    /// The next scripted arrival, or nil when the reader is cancelled.
    func next() async -> ApplicationArrival? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> ApplicationArrival? in
                    guard state.pending.isEmpty else { return state.pending.removeFirst() }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
    }
}

/// A window input over the fakes, its bus, and its scripted events.
private struct WindowHarness {
    /// The input under test.
    let input: WindowInput

    /// The captures it starts.
    let captures: FakeWindowCaptures

    /// The bus's events, read in order.
    var events: AsyncStream<EventBusEvent>.Iterator

    /// Scripts the displays sleeping and waking.
    let power: AsyncStream<DisplayPowerEvent>.Continuation

    /// Scripts applications launching and coming to the front.
    let arrivals: ArrivalQueue

    /// Fires each time the input asks for the next arrival: once when it
    /// subscribes, and again after each arrival has been handed to its
    /// session — so a test can order an arrival ahead of what it does next.
    let arrivalPulls: AsyncStream<Void>

    /// Builds the harness.
    ///
    /// - Parameters:
    ///   - windowID: The identifier the input is created with.
    ///   - authorized: Whether Screen Recording is granted.
    ///   - absences: The start attempts that find no window.
    ///   - rejections: The start attempts that throw as a rejected
    ///     configuration.
    init(
        windowID: UInt32? = nil,
        authorized: Bool = true,
        absences: Set<Int> = [],
        rejections: Set<Int> = []
    ) {
        let captures = FakeWindowCaptures(absences: absences, rejections: rejections)
        let eventBus = EventBus()
        let (powerEvents, power) = AsyncStream.makeStream(of: DisplayPowerEvent.self)
        let arrivals = ArrivalQueue()
        let (arrivalPulls, pulled) = AsyncStream.makeStream(of: Void.self)
        let arrivalEvents = AsyncStream<ApplicationArrival> {
            pulled.yield()
            return await arrivals.next()
        }
        self.arrivalPulls = arrivalPulls
        self.captures = captures
        self.events = eventBus.events().makeAsyncIterator()
        self.power = power
        self.arrivals = arrivals
        self.input = WindowInput(
            target: deck,
            id: deckInputID,
            windowID: windowID,
            eventBus: eventBus,
            requestAuthorization: { authorized },
            powerEvents: { powerEvents },
            applicationArrivals: { arrivalEvents },
            startCapture: captures.starter
        )
    }

    /// The next event the input reports.
    mutating func nextEvent() async -> EventBusEvent? {
        await events.next()
    }

    /// Scripts the window's application coming to the front.
    func keynoteArrives() {
        arrivals.push(ApplicationArrival(bundleIdentifier: deck.bundleIdentifier))
    }
}

/// Creates a small frame for delivery tests.
private func makeWindowFrame() throws -> CapturedFrame {
    var bufferOut: CVPixelBuffer?
    try #require(
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &bufferOut)
            == kCVReturnSuccess
    )
    return CapturedFrame(pixelBuffer: try #require(bufferOut), presentationTime: .zero)
}

@Suite("Window input")
struct WindowInputTests {
    @Test("a window input is a video input of the window kind, named for its target")
    func identity() {
        let harness = WindowHarness()
        #expect(harness.input.id == deckInputID)
        #expect(harness.input.name == "Keynote — Launch Deck")
        #expect(harness.input.kind == .window)
        #expect(harness.input.media == .video)
    }

    @Test("start throws authorizationDenied naming Screen Recording when access is denied")
    func deniedAuthorizationThrows() async {
        let harness = WindowHarness(authorized: false)
        await #expect(throws: CaptureInputError.authorizationDenied(.window, deckInputID)) {
            try await harness.input.start()
        }
        #expect(harness.captures.attemptCount == 0)
        #expect(
            String(describing: CaptureInputError.authorizationDenied(.window, deckInputID))
                .contains("Screen Recording"))
    }

    @Test("start throws when ScreenCaptureKit rejects the stream for a window it found")
    func rejectedStartThrows() async {
        let harness = WindowHarness(rejections: [0])
        await #expect(throws: CaptureInputError.configurationRejected(deckInputID, "The stream could not start")) {
            try await harness.input.start()
        }
    }

    @Test("the first capture asks for the window the operator picked")
    func firstCaptureUsesThePickedWindow() async throws {
        let harness = WindowHarness(windowID: 77)
        try await harness.input.start()
        #expect(harness.captures.requestedWindowIDs == [77])
        await harness.input.stop()
    }

    @Test("frames delivered by the capture reach the input's stream")
    func deliversFrames() async throws {
        let harness = WindowHarness()
        try await harness.input.start()
        var frames = harness.input.frames().makeAsyncIterator()
        harness.captures.deliver(try makeWindowFrame(), through: 0)
        #expect(await frames.next() != nil)
        await harness.input.stop()
        #expect(await frames.next() == nil)
    }

    @Test("a window that is not open starts anyway and reports input.interrupted as a normal event")
    func missingWindowWaits() async throws {
        var harness = WindowHarness(absences: [0])
        try await harness.input.start()

        let event = try #require(await harness.nextEvent())
        #expect(event.name == "input.interrupted")
        #expect(event.group == .event)
        #expect(event.params?["reason"] == .string("windowUnavailable"))
        #expect(event.params?["id"] == .string(deckInputID.rawValue))
        #expect(event.params?["name"] == .string("Keynote — Launch Deck"))
        #expect(harness.captures.startCount == 0)
        await harness.input.stop()
    }

    @Test("the application coming to the front starts the waiting capture and reports input.resumed")
    func arrivalResumesAWaitingInput() async throws {
        var harness = WindowHarness(absences: [0])
        try await harness.input.start()
        #expect(await harness.nextEvent()?.name == "input.interrupted")

        harness.keynoteArrives()
        let resumed = try #require(await harness.nextEvent())
        #expect(resumed.name == "input.resumed")
        #expect(resumed.group == .event)
        #expect(harness.captures.startCount == 1)
        await harness.input.stop()
    }

    @Test("an arrival that still finds no window reports nothing, and the next one tries again")
    func arrivalWithoutTheWindowStaysQuiet() async throws {
        var harness = WindowHarness(absences: [0, 1])
        try await harness.input.start()
        #expect(await harness.nextEvent()?.name == "input.interrupted")

        harness.keynoteArrives()
        harness.keynoteArrives()
        // The first event after the interruption is the resume, which
        // proves the arrival that found nothing reported nothing.
        #expect(await harness.nextEvent()?.name == "input.resumed")
        #expect(harness.captures.attemptCount == 3)
        await harness.input.stop()
    }

    @Test("another application coming to the front does not look for the window")
    func otherApplicationsAreIgnored() async throws {
        var harness = WindowHarness(absences: [0])
        try await harness.input.start()
        #expect(await harness.nextEvent()?.name == "input.interrupted")

        harness.arrivals.push(ApplicationArrival(bundleIdentifier: "com.apple.finder"))
        harness.keynoteArrives()
        #expect(await harness.nextEvent()?.name == "input.resumed")
        #expect(harness.captures.attemptCount == 2)
        await harness.input.stop()
    }

    @Test("an arrival while the capture is running starts nothing")
    func arrivalWhileRunningIsIgnored() async throws {
        var harness = WindowHarness()
        var pulls = harness.arrivalPulls.makeAsyncIterator()
        try await harness.input.start()
        await pulls.next()
        harness.keynoteArrives()
        // The input asking for the next arrival means this one has reached
        // its session, ahead of the end sent below.
        await pulls.next()
        // The closed window's interruption is the first event, so the
        // arrival before it produced none.
        harness.captures.end(capture: 0, .failed("The window was closed"))
        #expect(await harness.nextEvent()?.name == "input.interrupted")
        #expect(harness.captures.attemptCount == 1)
        await harness.input.stop()
    }

    @Test("a window closed mid-capture reports streamFailed, and the application's return resumes it")
    func closedWindowResumesOnArrival() async throws {
        var harness = WindowHarness(windowID: 77)
        try await harness.input.start()
        harness.captures.end(capture: 0, .failed("The window was closed"))

        let interrupted = try #require(await harness.nextEvent())
        #expect(interrupted.name == "input.interrupted")
        #expect(interrupted.params?["reason"] == .string("streamFailed"))
        #expect(interrupted.params?["error"] == .string("The window was closed"))
        #expect(harness.captures.stopped == [0])

        harness.keynoteArrives()
        #expect(await harness.nextEvent()?.name == "input.resumed")
        // The restart asks for the window the first capture actually held.
        #expect(harness.captures.requestedWindowIDs == [77, 40])
        await harness.input.stop()
    }

    @Test("a restart that cannot start reports input.resume as an error, and the next arrival tries again")
    func rejectedResumeRetries() async throws {
        var harness = WindowHarness(absences: [0], rejections: [1])
        try await harness.input.start()
        #expect(await harness.nextEvent()?.name == "input.interrupted")

        harness.keynoteArrives()
        let failed = try #require(await harness.nextEvent())
        #expect(failed.name == "input.resume")
        #expect(failed.group == .error)

        harness.keynoteArrives()
        #expect(await harness.nextEvent()?.name == "input.resumed")
        await harness.input.stop()
    }

    @Test("a display sleep stops the capture, and the wake restarts it")
    func sleepAndWake() async throws {
        var harness = WindowHarness()
        try await harness.input.start()
        harness.power.yield(.slept)
        harness.power.yield(.woke)

        let interrupted = try #require(await harness.nextEvent())
        #expect(interrupted.name == "input.interrupted")
        #expect(interrupted.params?["reason"] == .string("displaySleep"))
        #expect(await harness.nextEvent()?.name == "input.resumed")
        #expect(harness.captures.stopped == [0])
        #expect(harness.captures.startCount == 2)
        await harness.input.stop()
    }

    @Test("an arrival while the displays sleep waits for the wake")
    func arrivalDuringSleepWaits() async throws {
        var harness = WindowHarness()
        try await harness.input.start()
        harness.power.yield(.slept)
        harness.keynoteArrives()
        harness.power.yield(.woke)

        #expect(await harness.nextEvent()?.name == "input.interrupted")
        #expect(await harness.nextEvent()?.name == "input.resumed")
        // One start at the wake, none for the arrival during the sleep.
        #expect(harness.captures.attemptCount == 2)
        await harness.input.stop()
    }

    @Test("a window that changes size reconfigures the capture to the new size")
    func resizeReconfigures() async throws {
        let harness = WindowHarness()
        try await harness.input.start()
        var resizes = harness.captures.resizes.makeAsyncIterator()

        harness.captures.resize(capture: 0, to: WindowPixelSize(width: 2000, height: 1200))
        #expect(await resizes.next() == WindowPixelSize(width: 2000, height: 1200))
        await harness.input.stop()
    }

    @Test("the same size reported twice reconfigures once")
    func repeatedSizeIsAppliedOnce() async throws {
        let harness = WindowHarness()
        try await harness.input.start()
        var resizes = harness.captures.resizes.makeAsyncIterator()
        let first = WindowPixelSize(width: 2000, height: 1200)
        let second = WindowPixelSize(width: 1000, height: 600)

        harness.captures.resize(capture: 0, to: first)
        #expect(await resizes.next() == first)
        harness.captures.resize(capture: 0, to: first)
        harness.captures.resize(capture: 0, to: second)
        // The next resize applied is the second size, so the repeat of the
        // first applied nothing.
        #expect(await resizes.next() == second)
        await harness.input.stop()
    }

    @Test("a size reported by a capture already replaced is ignored")
    func lateResizeIgnored() async throws {
        var harness = WindowHarness()
        try await harness.input.start()
        harness.power.yield(.woke)
        #expect(await harness.nextEvent()?.name == "input.resumed")
        var resizes = harness.captures.resizes.makeAsyncIterator()

        harness.captures.resize(capture: 0, to: WindowPixelSize(width: 640, height: 480))
        harness.captures.resize(capture: 1, to: WindowPixelSize(width: 800, height: 600))
        #expect(await resizes.next() == WindowPixelSize(width: 800, height: 600))
        await harness.input.stop()
    }

    @Test("stop ends the session and stops the running capture, and may be called twice")
    func stopIsIdempotent() async throws {
        let harness = WindowHarness()
        try await harness.input.start()
        await harness.input.stop()
        await harness.input.stop()
        #expect(harness.captures.startCount == 1)
    }
}

@Suite("Window input provider")
struct WindowInputProviderTests {
    @Test("the provider offers the windows on screen, in picker order")
    func availableWindows() async throws {
        let provider = WindowInputProvider(eventBus: nil) {
            [
                window(1, title: "Roadmap"),
                window(2, title: "Hidden", isOnScreen: false),
                window(3, bundle: "com.apple.finder", application: "Finder", title: "Downloads"),
            ]
        }
        #expect(try await provider.availableWindows().map(\.id) == [3, 1])
    }

    @Test("the provider passes on a denied Screen Recording answer")
    func deniedListingThrows() async {
        let provider = WindowInputProvider(eventBus: nil) { throw WindowListingError.screenRecordingDenied }
        await #expect(throws: WindowListingError.screenRecordingDenied) {
            _ = try await provider.availableWindows()
        }
    }

    @Test("the provider makes a window input reporting the project's identifier")
    func makesAnInput() {
        let input = WindowInputProvider(eventBus: nil) { [] }.makeInput(for: deck, id: deckInputID, windowID: 12)
        #expect(input.id == deckInputID)
        #expect(input.name == "Keynote — Launch Deck")
        #expect(input.kind == .window)
        #expect(input.media == .video)
    }

    @Test("listing errors describe the cause and the fix, and compare by case")
    func listingErrorDescriptions() {
        #expect(String(describing: WindowListingError.screenRecordingDenied).contains("Screen Recording"))
        #expect(String(describing: WindowListingError.unavailable("no display")).contains("no display"))
        #expect(WindowListingError.unavailable("a") == WindowListingError.unavailable("a"))
        #expect(WindowListingError.unavailable("a") != WindowListingError.unavailable("b"))
        #expect(WindowListingError.screenRecordingDenied != WindowListingError.unavailable("a"))
    }
}
