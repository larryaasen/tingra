//
//  DisplayInput.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import Synchronization
import TingraEventBus
import TingraPlugInKit

/// A display behind the `Input` seam: an `SCStream` (ScreenCaptureKit)
/// delivering `IOSurface`-backed 32BGRA frames, tagged BT.709 at this seam
/// (ARCHITECTURE.md, "Color and pixel format conventions") — nothing
/// downstream imports ScreenCaptureKit.
///
/// Frames arrive already stamped against the host time clock by
/// ScreenCaptureKit, so timestamp normalization is the identity here — zero
/// clock domain translation, per CLOCK.md ("Why the host time clock").
///
/// **A capture outlives a display sleep** (2026-09-26). ScreenCaptureKit
/// stops the stream itself the moment the displays sleep — even for a
/// fraction of a second — and never starts it again, which left a display
/// layer frozen on its last frame for the rest of the show with nothing on
/// the bus to say why. The input now reports every stop the capture makes
/// on its own as a normal `input.interrupted` event, and starts a fresh
/// capture when the displays wake (``DisplayPower``), reporting
/// `input.resumed`. The frame stream stays open throughout, so the layer
/// holds its last frame while the displays sleep and picks up the new
/// capture with no change to the shot (ARCHITECTURE.md, "Display capture
/// across display sleep").
///
/// Concurrency: the non-`Sendable` capture lives entirely inside one
/// session task that `start()` spawns and `stop()` ends — it never crosses
/// an isolation boundary, so the input needs no `@unchecked Sendable` (the
/// frame ownership rule covers the frames themselves). The session is a
/// small state machine over the signals it is sent (``SessionSignal``), and
/// the capture itself is injected (``DisplayCaptureStarter``), so the
/// interruption and resume rules are unit-tested without ScreenCaptureKit
/// or the Screen Recording TCC prompt; the real capture is a hardware path
/// and gets this seam, not unit tests (CLAUDE.md, Testing).
final class DisplayInput: Input, Sendable {
    /// The discovered display this input captures from.
    private let display: DisplayDevice

    /// The host's event bus, for the interruption and resume events, or nil
    /// where nothing listens.
    private let eventBus: EventBus?

    /// Requests Screen Recording authorization, returning whether access is
    /// granted. Production asks ScreenCaptureKit
    /// (`SCShareableContent.current` succeeds only once granted); tests
    /// inject a fixed answer.
    private let requestAuthorization: @Sendable () async -> Bool

    /// Subscribes to display sleep and wake. Production observes
    /// `NSWorkspace` (``DisplayPower/liveEvents()``); tests script the
    /// events.
    private let powerEvents: @Sendable () -> AsyncStream<DisplayPowerEvent>

    /// Starts one capture of the display. Production starts an `SCStream`;
    /// tests inject a fake.
    private let startCapture: DisplayCaptureStarter

    /// The running session's signal stream and the single active frame
    /// continuation. One holder at a time, per the frame ownership rule
    /// (ARCHITECTURE.md): a new `frames()` call finishes and replaces the
    /// previous stream.
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
    }

    /// Creates a display input over a discovered display.
    ///
    /// - Parameters:
    ///   - display: The discovered display.
    ///   - eventBus: The host's event bus, for `input.interrupted`,
    ///     `input.resumed`, and a failed resume. Omit it where nothing
    ///     listens.
    ///   - requestAuthorization: The authorization seam; defaults to the
    ///     real Screen Recording check.
    ///   - powerEvents: The display sleep and wake seam; defaults to
    ///     `NSWorkspace`'s notifications.
    ///   - startCapture: The capture seam; defaults to ScreenCaptureKit.
    init(
        display: DisplayDevice,
        eventBus: EventBus? = nil,
        requestAuthorization: @escaping @Sendable () async -> Bool = DisplayInput.requestScreenRecordingAccess,
        powerEvents: @escaping @Sendable () -> AsyncStream<DisplayPowerEvent> = DisplayPower.liveEvents,
        startCapture: @escaping DisplayCaptureStarter = DisplayInput.startScreenCapture
    ) {
        self.display = display
        self.eventBus = eventBus
        self.requestAuthorization = requestAuthorization
        self.powerEvents = powerEvents
        self.startCapture = startCapture
    }

    /// The stable identifier — the display's UUID, verbatim, so a resolved
    /// display selection survives reconnection.
    var id: InputID { InputID(rawValue: display.uniqueID) }

    /// The user-facing display name.
    var name: String { display.name }

    /// A display.
    var kind: InputKind { .display }

    /// A display produces video only. System audio capture is a later
    /// ScreenCaptureKit surface; when it lands this becomes `[.video, .audio]`.
    var media: InputMedia { .video }

    /// Requests authorization, starts the capture, and runs the session
    /// that keeps it going across display sleep.
    ///
    /// Throws ``CaptureInputError/authorizationDenied(_:_:)`` when Screen
    /// Recording access is denied, ``CaptureInputError/deviceUnavailable(_:)``
    /// when the display has disconnected since discovery, and
    /// ``CaptureInputError/configurationRejected(_:_:)`` when ScreenCaptureKit
    /// cannot start the stream. Everything after a successful start is an
    /// event, never a throw: a capture that stops is `input.interrupted`, a
    /// wake that restarts it is `input.resumed`, and a restart that fails is
    /// an `input.resume` error, retried at the next wake. Display
    /// disconnection is a normal event reported by the plug-in.
    func start() async throws {
        guard await requestAuthorization() else {
            throw CaptureInputError.authorizationDenied(.display, id)
        }

        let (signals, signal) = AsyncStream.makeStream(of: SessionSignal.self)
        let display = self.display
        let inputID = id
        let startCapture = self.startCapture
        let powerEvents = self.powerEvents
        let report = SessionReporter(eventBus: eventBus, id: inputID, name: name)
        let deliver: @Sendable (CapturedFrame) -> Void = { [weak self] frame in
            self?.state.withLock { $0.continuation }?.yield(frame)
        }
        // Each capture reports its own end tagged with its generation.
        let capture: @Sendable (Int) async throws -> any DisplayCapture = { generation in
            try await startCapture(display, inputID, deliver) { end in
                signal.yield(.captureEnded(generation: generation, end))
            }
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            Task {
                var generation = 0
                var running: (any DisplayCapture)?
                do {
                    running = try await capture(generation)
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
                // Until stop() finishes the signal stream. Holding `running`
                // here is what keeps the capture alive (``RunningStream``).
                for await next in signals {
                    switch next {
                    case .captureEnded(let ended, let end):
                        guard ended == generation, let stopped = running else { continue }
                        running = nil
                        await stopped.stop()
                        report.interrupted(reason: end.reason, error: end.message)
                    case .power(.slept):
                        guard let stopped = running else { continue }
                        running = nil
                        await stopped.stop()
                        report.interrupted(reason: "displaySleep", error: nil)
                    case .power(.woke):
                        // Restart whether or not a stop was seen:
                        // ScreenCaptureKit stops the capture at display sleep
                        // without always saying so, and a capture that did
                        // survive loses a moment, not the show.
                        if let previous = running {
                            running = nil
                            await previous.stop()
                        }
                        generation += 1
                        do {
                            running = try await capture(generation)
                            report.resumed()
                        } catch {
                            report.resumeFailed(error)
                        }
                    }
                }
                power.cancel()
                await running?.stop()
            }
        }
        state.withLock { $0.signal = signal }
    }

    /// The stream of captured frames. One consumer at a time: a new call
    /// finishes the previous stream and takes over, per the frame ownership
    /// rule. It stays open across display sleep — the consumer sees no
    /// frames while the displays sleep, then the restarted capture's.
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

    /// Reports the session's interruptions and resumes on the bus, carrying
    /// the input's identity so every event names the display it is about.
    private struct SessionReporter: Sendable {
        /// The bus, or nil where nothing listens.
        let eventBus: EventBus?

        /// The input's identifier.
        let id: InputID

        /// The input's name.
        let name: String

        /// The params every event carries.
        private var identity: [String: EventValue] {
            ["id": .string(id.rawValue), "name": .string(name)]
        }

        /// The capture stopped — a normal event, like a disconnection
        /// (CLAUDE.md, Data Flow Rules): the layer holds its last frame.
        ///
        /// - Parameters:
        ///   - reason: Why: `displaySleep`, `streamStopped`, or
        ///     `streamFailed`.
        ///   - error: ScreenCaptureKit's description, for `streamFailed`.
        func interrupted(reason: String, error: String?) {
            var params = identity
            params["reason"] = .string(reason)
            if let error { params["error"] = .string(error) }
            eventBus?.event("input.interrupted", domain: .capture, params: params)
        }

        /// A fresh capture started after the displays woke.
        func resumed() {
            eventBus?.event("input.resumed", domain: .capture, params: identity)
        }

        /// The fresh capture could not start; the next wake tries again.
        ///
        /// - Parameter error: Why it could not start.
        func resumeFailed(_ error: any Error) {
            var params = identity
            params["error"] = .string(String(describing: error))
            eventBus?.error("input.resume", domain: .capture, params: params)
        }
    }

    /// The production capture seam: an `SCStream` over the display.
    static let startScreenCapture: DisplayCaptureStarter = { display, id, deliver, ended in
        try await makeRunningStream(for: display, id: id, deliver: deliver, ended: ended)
    }

    /// A running capture stream together with the output object it delivers
    /// through.
    ///
    /// The two travel as a pair because `SCStream` holds **neither** its
    /// delegate nor an added stream output strongly. Keeping only the stream
    /// alive lets the output deallocate the moment the call that built it
    /// returns — after which the stream keeps running and keeps the system's
    /// screen-recording indicator lit while delivering **no frames at all**,
    /// which is a hard failure to read from the outside: `start()` succeeds,
    /// nothing errors, and every tile bound to the display simply stays black.
    /// Holding both for the stream's lifetime is what makes the capture
    /// actually produce pixels.
    private struct RunningStream: DisplayCapture {
        /// The capture stream.
        let stream: SCStream

        /// The output the stream delivers through, held solely to keep it
        /// alive — `SCStream` will not.
        let output: DisplayStreamOutput

        /// Stops the stream. One ScreenCaptureKit already stopped reports an
        /// error here, which is the state asked for and is ignored.
        func stop() async {
            try? await stream.stopCapture()
        }
    }

    /// Builds, configures, and starts the capture stream for a display.
    ///
    /// Resolves the display's current `CGDirectDisplayID` from its stable
    /// UUID (the ID changes across reconnects; the UUID does not), matches
    /// it against ScreenCaptureKit's shareable content, and starts an
    /// `SCStream` delivering 32BGRA frames at native pixel size.
    ///
    /// - Parameters:
    ///   - display: The display to capture.
    ///   - id: The input's identifier, for errors.
    ///   - deliver: Hands each frame on.
    ///   - ended: Called when the stream stops on its own.
    /// - Returns: The started stream and its output, which the caller must
    ///   keep alive together (see ``RunningStream``).
    private static func makeRunningStream(
        for display: DisplayDevice,
        id: InputID,
        deliver: @escaping @Sendable (CapturedFrame) -> Void,
        ended: @escaping @Sendable (DisplayCaptureEnd) -> Void
    ) async throws -> RunningStream {
        guard let displayID = currentDisplayID(forUUID: display.uniqueID) else {
            throw CaptureInputError.deviceUnavailable(id)
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            // Enumeration fails without Screen Recording authorization; the
            // injected check has already passed here, so a failure means the
            // content could not be read for another reason.
            throw CaptureInputError.configurationRejected(
                id,
                "ScreenCaptureKit could not read the shareable content: \(error.localizedDescription)"
            )
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureInputError.deviceUnavailable(id)
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        // Native pixel size: capture at the display's own resolution and let
        // the compositor scale to the program format (one conversion point).
        configuration.width = display.pixelWidth
        configuration.height = display.pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Frames leave through the delivery closure; the tick paces the
        // program, so a generous queue depth only buffers native frames.
        configuration.queueDepth = 6

        let output = DisplayStreamOutput(deliver: deliver, ended: ended)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            // The output runs on its own queue: the callback immediately
            // crosses into the delivery closure, and no other code runs on it.
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "com.moonwink.tingra.capture.display")
            )
            try await stream.startCapture()
        } catch {
            throw CaptureInputError.configurationRejected(
                id,
                "the display capture stream did not start: \(error.localizedDescription)"
            )
        }
        return RunningStream(stream: stream, output: output)
    }

    /// Translates a display UUID into its current `CGDirectDisplayID`, or
    /// nil if no active display matches (it disconnected since discovery).
    private static func currentDisplayID(forUUID uuid: String) -> CGDirectDisplayID? {
        for displayID in activeDisplayIDs() where displayUUIDString(for: displayID) == uuid {
            return displayID
        }
        return nil
    }

    /// The production authorization seam: probes Screen Recording access by
    /// attempting to read the shareable content, which succeeds only once
    /// the permission is granted (no dedicated request API exists — the
    /// first attempt is what prompts).
    private static let requestScreenRecordingAccess: @Sendable () async -> Bool = {
        (try? await SCShareableContent.current) != nil
    }
}

/// One running capture of a display, as the input's session holds it — an
/// `SCStream` and its output in production, a fake in tests. Not
/// `Sendable`: it never leaves the session task.
protocol DisplayCapture {
    /// Stops the capture. Stopping one that already ended is harmless.
    func stop() async
}

/// Why a capture ended on its own.
enum DisplayCaptureEnd: Sendable, Equatable {
    /// ScreenCaptureKit stopped the stream — what it does when the displays
    /// sleep, reported through the frame status.
    case stopped

    /// ScreenCaptureKit stopped the stream with an error, described.
    case failed(String)

    /// The `reason` param of the `input.interrupted` event.
    var reason: String {
        switch self {
        case .stopped: "streamStopped"
        case .failed: "streamFailed"
        }
    }

    /// The `error` param, for a failure.
    var message: String? {
        switch self {
        case .stopped: nil
        case .failed(let message): message
        }
    }
}

/// Starts one capture of a display: given the display, the input's
/// identifier, where frames go, and what to call when the capture ends on its
/// own, returns the running capture or throws why it could not start.
typealias DisplayCaptureStarter =
    @Sendable (
        _ display: DisplayDevice,
        _ id: InputID,
        _ deliver: @escaping @Sendable (CapturedFrame) -> Void,
        _ ended: @escaping @Sendable (DisplayCaptureEnd) -> Void
    ) async throws -> any DisplayCapture

/// The active displays and their stable UUID strings, read from
/// CoreGraphics — discovery that needs no Screen Recording authorization
/// (listing displays never prompts; only capturing one does).
///
/// Kept free of ScreenCaptureKit so the plug-in can list displays before
/// asking for the Screen Recording permission, mirroring how camera
/// discovery lists devices without a camera prompt.
enum DisplayDiscovery {
    /// The connected displays, in CoreGraphics' active order, reduced to the
    /// framework-free ``DisplayDevice`` the plug-in and its tests work with.
    static func connectedDisplays() -> [DisplayDevice] {
        activeDisplayIDs().enumerated().compactMap { index, displayID in
            guard let uuid = displayUUIDString(for: displayID) else { return nil }
            return DisplayDevice(
                uniqueID: uuid,
                name: displayName(for: displayID, index: index),
                pixelWidth: CGDisplayPixelsWide(displayID),
                pixelHeight: CGDisplayPixelsHigh(displayID)
            )
        }
    }

    /// A user-facing display name. CoreGraphics exposes no localized name
    /// without a private framework, so displays are named by role (the main
    /// display) and position, which is stable and needs no extra
    /// authorization.
    private static func displayName(for displayID: CGDirectDisplayID, index: Int) -> String {
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }
        if CGMainDisplayID() == displayID {
            return "Main Display"
        }
        return "Display \(index + 1)"
    }
}

/// The active `CGDirectDisplayID`s, in CoreGraphics' order (needs no
/// authorization). Shared by discovery and by capture's UUID→ID resolution.
private func activeDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

/// The display's stable UUID as a string
/// (`CGDisplayCreateUUIDFromDisplayID`), or nil if CoreGraphics has none —
/// the identifier that survives reboots and reconnects, unlike the
/// `CGDirectDisplayID` itself.
private func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
    guard let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return nil }
    return string as String
}

/// Bridges ScreenCaptureKit's output callback into the frame stream, and
/// reports the stream stopping on its own — which it does when the displays
/// sleep — as the normal event it is (a display sleeping is not a failure).
/// Confined to the stream's sample-handler queue; each delivered buffer is
/// tagged if the framework left it untagged, keeps its host clock PTS, and
/// leaves through `deliver` — transferring ownership at the yield, per the
/// frame ownership rule.
private final class DisplayStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Hands one normalized frame to the input's live stream.
    private let deliver: @Sendable (CapturedFrame) -> Void

    /// Tells the input's session the stream ended on its own.
    private let ended: @Sendable (DisplayCaptureEnd) -> Void

    /// Creates an output delivering frames through the given closure.
    ///
    /// - Parameters:
    ///   - deliver: Hands each frame on.
    ///   - ended: Called when the stream stops on its own.
    init(deliver: @escaping @Sendable (CapturedFrame) -> Void, ended: @escaping @Sendable (DisplayCaptureEnd) -> Void) {
        self.deliver = deliver
        self.ended = ended
    }

    /// Normalizes and forwards one captured sample buffer, skipping the
    /// idle/blank frames ScreenCaptureKit emits when the screen is
    /// unchanged (only `.complete` frames carry new pixels), and reporting a
    /// `.stopped` frame — ScreenCaptureKit's word that it has stopped the
    /// stream, which it does when the displays sleep.
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        let status = Self.frameStatus(of: sampleBuffer)
        if status == .stopped {
            ended(.stopped)
            return
        }
        guard status == .complete, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        FrameNormalization.tagBT709IfUntagged(pixelBuffer)
        deliver(
            CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
        )
    }

    /// The stream stopped with an error — reported, never thrown: the
    /// session reports it as `input.interrupted` and tries again at the next
    /// display wake.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        ended(.failed(error.localizedDescription))
    }

    /// The frame status ScreenCaptureKit attached to a sample buffer, or nil
    /// when it attached none.
    private static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: statusRaw)
    }
}
