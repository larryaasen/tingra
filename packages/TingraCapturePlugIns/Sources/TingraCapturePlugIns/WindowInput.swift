//
//  WindowInput.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import Synchronization
import TingraEventBus
import TingraPlugInKit

/// One window behind the `Input` seam: an `SCStream` over a
/// desktop-independent window filter, so the window is captured alone
/// wherever it sits — behind other windows, on another display — delivering
/// the same `IOSurface`-backed 32BGRA frames, tagged BT.709 and stamped
/// against the host time clock, that ``DisplayInput`` does.
///
/// Three things a window does that a display does not shape this input
/// (ARCHITECTURE.md, "Window capture"):
///
/// - **It has no stable identifier**, so the input holds a ``WindowTarget``
///   and finds the window that fits it at every capture start
///   (``WindowMatching``).
/// - **It may not be there.** A project opens before the application it
///   captures does, and a window closes mid-show. Neither is an error: the
///   input starts, reports `input.interrupted` with the reason
///   `windowUnavailable`, and looks again when the application launches or
///   comes to the front (``ApplicationActivity``) — an event, never a poll.
///   A capture that ends because its window closed is `input.interrupted`
///   too, and resumes the same way.
/// - **It changes size.** ScreenCaptureKit delivers the size the stream was
///   configured with, so the session reconfigures the stream whenever a
///   frame shows the window at another size, and the frames stay the
///   window's own pixels.
///
/// Display sleep stops a window capture exactly as it stops a display's, and
/// it is handled the same way: stopped and reported at sleep, restarted at
/// wake.
///
/// Concurrency: as in ``DisplayInput``, the non-`Sendable` capture lives
/// inside one session task that `start()` spawns and `stop()` ends, the
/// session is a state machine over the signals it is sent, and the capture
/// is injected (``WindowCaptureStarter``) so every rule here is unit-tested
/// without ScreenCaptureKit or the Screen Recording prompt.
final class WindowInput: Input, Sendable {
    /// The input's stable identifier — the project's, since a window has
    /// none of its own.
    let id: InputID

    /// The window this input captures, as the project remembers it.
    private let target: WindowTarget

    /// The identifier the window had when the operator chose it, when this
    /// input was made from the picker; nil for one made from a saved
    /// project.
    private let initialWindowID: UInt32?

    /// The host's event bus, for the interruption and resume events, or nil
    /// where nothing listens.
    private let eventBus: EventBus?

    /// Requests Screen Recording authorization, returning whether access is
    /// granted.
    private let requestAuthorization: @Sendable () async -> Bool

    /// Subscribes to display sleep and wake.
    private let powerEvents: @Sendable () -> AsyncStream<DisplayPowerEvent>

    /// Subscribes to applications launching and coming to the front.
    private let applicationArrivals: @Sendable () -> AsyncStream<ApplicationArrival>

    /// Starts one capture of the window. Production starts an `SCStream`;
    /// tests inject a fake.
    private let startCapture: WindowCaptureStarter

    /// The running session's signal stream and the single active frame
    /// continuation — one holder at a time, per the frame ownership rule.
    private let state = Mutex<CaptureState>(CaptureState())

    /// The mutable capture state behind the mutex — `Sendable` handles
    /// only; the capture itself stays inside its task.
    private struct CaptureState {
        /// Finishing this ends the session task, while started.
        var signal: AsyncStream<SessionSignal>.Continuation?

        /// The single active frame continuation, while a consumer is
        /// attached.
        var continuation: AsyncStream<CapturedFrame>.Continuation?
    }

    /// What the session task reacts to, in the order it arrives.
    private enum SessionSignal: Sendable {
        /// A capture ended on its own. Tagged with the capture's generation,
        /// so a late report from a capture already replaced is ignored.
        case captureEnded(generation: Int, DisplayCaptureEnd)

        /// The displays slept or woke.
        case power(DisplayPowerEvent)

        /// The window's application launched or came to the front.
        case applicationArrived

        /// A frame showed the window at another size than the stream
        /// delivers; the size is read from ``PendingSize``. Tagged with the
        /// capture's generation, like an end.
        case resized(generation: Int)
    }

    /// The newest size a capture's frames reported, held outside the signal
    /// so a window being dragged — a new size with every frame — costs one
    /// reconfiguration to the size it has when the session gets to it, not
    /// one per frame.
    private final class PendingSize: Sendable {
        /// The size, or nil when none is waiting.
        private let size = Mutex<WindowPixelSize?>(nil)

        /// Records the newest size.
        ///
        /// - Parameter newest: The size a frame reported.
        func set(_ newest: WindowPixelSize) {
            size.withLock { $0 = newest }
        }

        /// The newest size recorded.
        var value: WindowPixelSize? {
            size.withLock { $0 }
        }
    }

    /// Creates a window input.
    ///
    /// - Parameters:
    ///   - target: The window to capture, as the project remembers it.
    ///   - id: The identifier the input reports — the project's identity for
    ///     the window.
    ///   - windowID: The window's identifier when the operator has just
    ///     chosen it, so the first capture is of exactly that window; nil
    ///     (the default) for a window loaded from a project.
    ///   - eventBus: The host's event bus. Omit it where nothing listens.
    ///   - requestAuthorization: The authorization seam; defaults to the
    ///     real Screen Recording check.
    ///   - powerEvents: The display sleep and wake seam.
    ///   - applicationArrivals: The application launch and activation seam.
    ///   - startCapture: The capture seam; defaults to ScreenCaptureKit.
    init(
        target: WindowTarget,
        id: InputID,
        windowID: UInt32? = nil,
        eventBus: EventBus? = nil,
        requestAuthorization: @escaping @Sendable () async -> Bool = DisplayInput.requestScreenRecordingAccess,
        powerEvents: @escaping @Sendable () -> AsyncStream<DisplayPowerEvent> = DisplayPower.liveEvents,
        applicationArrivals: @escaping @Sendable () -> AsyncStream<ApplicationArrival> = ApplicationActivity
            .liveArrivals,
        startCapture: @escaping WindowCaptureStarter = WindowInput.startWindowCapture
    ) {
        self.target = target
        self.id = id
        self.initialWindowID = windowID
        self.eventBus = eventBus
        self.requestAuthorization = requestAuthorization
        self.powerEvents = powerEvents
        self.applicationArrivals = applicationArrivals
        self.startCapture = startCapture
    }

    /// The user-facing name: the application, then the window's title as it
    /// was when chosen.
    var name: String { target.name }

    /// A window.
    var kind: InputKind { .window }

    /// A window produces video only.
    var media: InputMedia { .video }

    /// Requests authorization, starts the capture if the window is open, and
    /// runs the session that keeps it going.
    ///
    /// Throws ``CaptureInputError/authorizationDenied(_:_:)`` when Screen
    /// Recording access is denied and
    /// ``CaptureInputError/configurationRejected(_:_:)`` when
    /// ScreenCaptureKit cannot start the stream for a window it found.
    /// **A window that is not open does not throw** — unlike a display gone
    /// since discovery: the input starts, reports `input.interrupted`
    /// (`windowUnavailable`), and begins capturing when the window can be
    /// found. Everything after a successful start is an event, never a
    /// throw, as with a display.
    func start() async throws {
        guard await requestAuthorization() else {
            throw CaptureInputError.authorizationDenied(.window, id)
        }

        let (signals, signal) = AsyncStream.makeStream(of: SessionSignal.self)
        let target = self.target
        let inputID = id
        let initialWindowID = self.initialWindowID
        let startCapture = self.startCapture
        let powerEvents = self.powerEvents
        let applicationArrivals = self.applicationArrivals
        let report = DisplayInput.SessionReporter(eventBus: eventBus, id: inputID, name: name)
        let pendingSize = PendingSize()
        let deliver: @Sendable (CapturedFrame) -> Void = { [weak self] frame in
            self?.state.withLock { $0.continuation }?.yield(frame)
        }
        // Each capture reports its own end and its window's size tagged with
        // its generation.
        let capture: @Sendable (Int, UInt32?) async throws -> any WindowCapture = { generation, lastWindowID in
            try await startCapture(
                target, lastWindowID, inputID, deliver,
                { end in signal.yield(.captureEnded(generation: generation, end)) },
                { size in
                    pendingSize.set(size)
                    signal.yield(.resized(generation: generation))
                }
            )
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            Task {
                var generation = 0
                var running: (any WindowCapture)?
                var lastWindowID = initialWindowID
                var appliedSize: WindowPixelSize?
                var displaysAsleep = false
                do {
                    running = try await capture(generation, lastWindowID)
                    lastWindowID = running?.windowID ?? lastWindowID
                } catch CaptureInputError.deviceUnavailable {
                    // The window is not open. A normal state for a window,
                    // reported and waited out, never thrown.
                    report.interrupted(reason: "windowUnavailable", error: nil)
                } catch {
                    ready.resume(throwing: error)
                    return
                }
                ready.resume()
                let power = Task {
                    for await event in powerEvents() {
                        signal.yield(.power(event))
                    }
                }
                let arrivals = Task {
                    for await arrival in applicationArrivals()
                    where arrival.bundleIdentifier == target.bundleIdentifier {
                        signal.yield(.applicationArrived)
                    }
                }
                // Until stop() finishes the signal stream. Holding `running`
                // here is what keeps the capture alive.
                for await next in signals {
                    switch next {
                    case .captureEnded(let ended, let end):
                        guard ended == generation, let stopped = running else { continue }
                        running = nil
                        await stopped.stop()
                        report.interrupted(reason: end.reason, error: end.message)
                    case .power(.slept):
                        displaysAsleep = true
                        guard let stopped = running else { continue }
                        running = nil
                        await stopped.stop()
                        report.interrupted(reason: "displaySleep", error: nil)
                    case .power(.woke):
                        displaysAsleep = false
                        // Restart whether or not a stop was seen, as a
                        // display capture does.
                        if let previous = running {
                            running = nil
                            await previous.stop()
                        }
                        generation += 1
                        appliedSize = nil
                        running = await Self.resume(generation, lastWindowID, capture: capture, report: report)
                        lastWindowID = running?.windowID ?? lastWindowID
                    case .applicationArrived:
                        // Only a session with no capture is looking for its
                        // window, and a capture started while the displays
                        // sleep is stopped at once.
                        guard running == nil, !displaysAsleep else { continue }
                        generation += 1
                        appliedSize = nil
                        running = await Self.resume(generation, lastWindowID, capture: capture, report: report)
                        lastWindowID = running?.windowID ?? lastWindowID
                    case .resized(let resized):
                        guard resized == generation, let capture = running, let size = pendingSize.value,
                            size != appliedSize
                        else { continue }
                        appliedSize = size
                        await capture.resize(to: size)
                    }
                }
                power.cancel()
                arrivals.cancel()
                await running?.stop()
            }
        }
        state.withLock { $0.signal = signal }
    }

    /// Starts a fresh capture for a session that has none, reporting
    /// `input.resumed` when it starts.
    ///
    /// A window that still cannot be found reports nothing: the session was
    /// already reported interrupted, and the next arrival tries again. Any
    /// other reason is an `input.resume` error.
    ///
    /// - Parameters:
    ///   - generation: The new capture's generation.
    ///   - lastWindowID: The identifier the window last had, if known.
    ///   - capture: Starts the capture.
    ///   - report: Reports the outcome.
    /// - Returns: The running capture, or nil when none started.
    private static func resume(
        _ generation: Int,
        _ lastWindowID: UInt32?,
        capture: @Sendable (Int, UInt32?) async throws -> any WindowCapture,
        report: DisplayInput.SessionReporter
    ) async -> (any WindowCapture)? {
        do {
            let running = try await capture(generation, lastWindowID)
            report.resumed()
            return running
        } catch CaptureInputError.deviceUnavailable {
            return nil
        } catch {
            report.resumeFailed(error)
            return nil
        }
    }

    /// The stream of captured frames. One consumer at a time: a new call
    /// finishes the previous stream and takes over. It stays open while the
    /// window is missing and across display sleep.
    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { continuation in
            let previous = state.withLock { state in
                let previous = state.continuation
                state.continuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    /// Ends the session task (which stops the capture) and finishes the
    /// frame stream. Safe to call more than once.
    func stop() async {
        let (signal, continuation) = state.withLock { state in
            let pair = (state.signal, state.continuation)
            state.signal = nil
            state.continuation = nil
            return pair
        }
        signal?.finish()
        continuation?.finish()
    }

    // MARK: ScreenCaptureKit

    /// The production capture seam: an `SCStream` over the window.
    static let startWindowCapture: WindowCaptureStarter = { target, lastWindowID, id, deliver, ended, resized in
        try await makeRunningStream(
            for: target, lastWindowID: lastWindowID, id: id, deliver: deliver, ended: ended, resized: resized)
    }

    /// The production window list: every capturable window open now.
    ///
    /// - Throws: ``WindowListingError/screenRecordingDenied`` without Screen
    ///   Recording access, ``WindowListingError/unavailable(_:)`` when
    ///   ScreenCaptureKit cannot read the list for another reason.
    static let listWindows: @Sendable () async throws -> [CaptureWindow] = {
        try await shareableWindows().map(\.record)
    }

    /// A running window capture: the stream, the output it delivers through
    /// (held because `SCStream` will not hold it — see
    /// ``DisplayInput``'s `RunningStream`), and the window it captures.
    private struct RunningWindowStream: WindowCapture {
        /// The capture stream.
        let stream: SCStream

        /// The output the stream delivers through.
        let output: ScreenStreamOutput

        /// The captured window's identifier.
        let windowID: UInt32

        /// Stops the stream; one already stopped reports an error, ignored.
        func stop() async {
            try? await stream.stopCapture()
        }

        /// Reconfigures the stream to deliver the window's new size. A
        /// reconfiguration ScreenCaptureKit refuses leaves the stream as it
        /// was — still delivering, the window scaled into the old size —
        /// which is a softer picture, not a failure worth an event.
        func resize(to size: WindowPixelSize) async {
            do {
                try await stream.updateConfiguration(WindowInput.configuration(for: size))
                output.setConfiguredSize(size)
            } catch {
                return
            }
        }
    }

    /// The stream configuration for a window delivered at the given size:
    /// 32BGRA at the window's own pixels, queued as shallowly as a display.
    ///
    /// - Parameter size: The size to deliver.
    /// - Returns: The configuration.
    private static func configuration(for size: WindowPixelSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = DisplayInput.captureQueueDepth
        return configuration
    }

    /// One ScreenCaptureKit window beside its framework-free record.
    private struct ShareableWindow {
        /// The record the rest of the plug-in works with.
        let record: CaptureWindow

        /// ScreenCaptureKit's own object, for building a content filter.
        let window: SCWindow
    }

    /// Every capturable window open now, on screen or not.
    ///
    /// Left out: desktop elements, anything above the normal window layer
    /// (menus, the Dock, overlays), windows with no title or no owning
    /// application to remember them by, and this process's own windows — a
    /// window of Tingra showing itself is a hall of mirrors.
    ///
    /// - Returns: The windows.
    /// - Throws: A ``WindowListingError``.
    private static func shareableWindows() async throws -> [ShareableWindow] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw WindowListingError.screenRecordingDenied
        } catch {
            throw WindowListingError.unavailable(error.localizedDescription)
        }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard window.windowLayer == 0, let application = window.owningApplication,
                application.processID != ownProcess, !application.bundleIdentifier.isEmpty,
                let title = window.title, !title.isEmpty, window.frame.width >= 1, window.frame.height >= 1
            else { return nil }
            let record = CaptureWindow(
                id: window.windowID,
                target: WindowTarget(
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.applicationName,
                    title: title
                ),
                width: Double(window.frame.width),
                height: Double(window.frame.height),
                isOnScreen: window.isOnScreen
            )
            return ShareableWindow(record: record, window: window)
        }
    }

    /// Finds the target's window, then builds, configures, and starts the
    /// capture stream for it, delivering 32BGRA frames at the window's own
    /// pixel size.
    ///
    /// - Parameters:
    ///   - target: The window to capture.
    ///   - lastWindowID: The identifier the window last had, if known.
    ///   - id: The input's identifier, for errors.
    ///   - deliver: Hands each frame on.
    ///   - ended: Called when the stream stops on its own.
    ///   - resized: Called when a frame shows the window at another size.
    /// - Returns: The started stream and its output, kept alive together.
    private static func makeRunningStream(
        for target: WindowTarget,
        lastWindowID: UInt32?,
        id: InputID,
        deliver: @escaping @Sendable (CapturedFrame) -> Void,
        ended: @escaping @Sendable (DisplayCaptureEnd) -> Void,
        resized: @escaping @Sendable (WindowPixelSize) -> Void
    ) async throws -> RunningWindowStream {
        let windows: [ShareableWindow]
        do {
            windows = try await shareableWindows()
        } catch {
            // The injected authorization check has already passed here, so
            // the list could not be read for another reason.
            throw CaptureInputError.configurationRejected(
                id,
                "ScreenCaptureKit could not read the window list: \(String(describing: error))"
            )
        }
        guard
            let match = WindowMatching.resolve(target, lastWindowID: lastWindowID, among: windows.map(\.record)),
            let window = windows.first(where: { $0.record.id == match.id })?.window
        else {
            throw CaptureInputError.deviceUnavailable(id)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        // The window's own pixels: its size in points on the display showing
        // it, at that display's scale. The compositor scales to the program
        // format (one conversion point).
        guard
            let size = WindowPixelSize.pixels(
                pointSize: filter.contentRect.size,
                scale: Double(filter.pointPixelScale)
            )
        else {
            throw CaptureInputError.configurationRejected(id, "the window '\(target.name)' reports no size")
        }

        let output = ScreenStreamOutput(deliver: deliver, ended: ended, configuredSize: size, resized: resized)
        let stream = SCStream(filter: filter, configuration: configuration(for: size), delegate: output)
        do {
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.moonwink.tingra.capture.window")
            )
            try await stream.startCapture()
        } catch {
            throw CaptureInputError.configurationRejected(
                id,
                "the window capture stream did not start: \(error.localizedDescription)"
            )
        }
        return RunningWindowStream(stream: stream, output: output, windowID: match.id)
    }
}

/// One running capture of a window, as the input's session holds it — an
/// `SCStream` and its output in production, a fake in tests. Not `Sendable`:
/// it never leaves the session task.
protocol WindowCapture: DisplayCapture {
    /// The identifier of the window being captured, so the next start can
    /// ask for the same one.
    var windowID: UInt32 { get }

    /// Reconfigures the capture to deliver the window's new size.
    ///
    /// - Parameter size: The window's size in pixels.
    func resize(to size: WindowPixelSize) async
}

/// Starts one capture of a window: given the target, the identifier the
/// window last had (if any), the input's identifier, where frames go, what
/// to call when the capture ends on its own, and what to call when the
/// window changes size, returns the running capture — or throws
/// ``CaptureInputError/deviceUnavailable(_:)`` when no open window fits the
/// target, or why the capture could not start.
typealias WindowCaptureStarter =
    @Sendable (
        _ target: WindowTarget,
        _ lastWindowID: UInt32?,
        _ id: InputID,
        _ deliver: @escaping @Sendable (CapturedFrame) -> Void,
        _ ended: @escaping @Sendable (DisplayCaptureEnd) -> Void,
        _ resized: @escaping @Sendable (WindowPixelSize) -> Void
    ) async throws -> any WindowCapture
