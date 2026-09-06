//
//  CameraInput.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Synchronization
import TingraEventBus
import TingraPlugInKit

/// A camera behind the `Input` seam: an `AVCaptureSession` delivering
/// `IOSurface`-backed 32BGRA frames, normalized and tagged BT.709 at this
/// seam (ARCHITECTURE.md, "Color and pixel format conventions") — nothing
/// downstream imports AVFoundation.
///
/// Frames arrive already stamped against the host time clock by
/// AVFoundation, so timestamp normalization is the identity here — zero
/// clock domain translation, per CLOCK.md ("Why the host time clock"); the
/// sync offset joins this normalization point when it lands.
///
/// Concurrency: the non-`Sendable` session and delegate live entirely
/// inside one session task that `start()` spawns and `stop()` signals —
/// they never cross an isolation boundary, so the input needs no
/// `@unchecked Sendable` (the frame ownership rule covers the frames
/// themselves). The capture machinery is a hardware path: it gets this
/// seam, not unit tests; the injected authorization check keeps the denied
/// path testable without TCC (CLAUDE.md, Testing).
///
/// **A start is only reported once a frame has actually arrived.**
/// `AVCaptureSession.startRunning()` neither throws nor returns a status,
/// and `isRunning` can read true even when the underlying CoreMedia I/O
/// graph never came up — observed 2026-09-06 with a USB camera whose
/// stream start timed out inside IOKit (`kIOReturnTimeout`,
/// `CMIOGraphStart` asserted) while the session still reported itself
/// running, so the input logged `input.started` and then delivered nothing
/// for as long as the app ran. The framework's runtime error notification
/// carries the real reason, but it is posted asynchronously, after
/// `startRunning()` has returned — so a check made in the startup window
/// alone can never see it. The proof of life is therefore the first
/// delivered frame, raced against a runtime error and a timeout, the same
/// gate the microphone applies to its tap's first callback; and the
/// runtime error stays observed for the session's whole lifetime, so a
/// device that dies mid-show is reported and released rather than left in
/// the program as a frozen frame.
final class CameraInput: Input, Sendable {
    /// The discovered device this input captures from.
    private let device: CaptureDevice

    /// Requests camera authorization, returning whether access is granted.
    /// Production asks TCC via `AVCaptureDevice.requestAccess`; tests
    /// inject a fixed answer.
    private let requestAuthorization: @Sendable () async -> Bool

    /// The host's event bus, for the capture diagnostics AVFoundation
    /// would otherwise only print to the console: a session that dies after
    /// a successful start. Optional so a test can build the input with no
    /// bus at all.
    private let eventBus: EventBus?

    /// The running session task's signal continuation and the single
    /// active frame continuation. One holder at a time, per the frame
    /// ownership rule (ARCHITECTURE.md): a new `frames()` call finishes
    /// and replaces the previous stream.
    private let state = Mutex<CaptureState>(CaptureState())

    /// The mutable capture state behind the mutex — `Sendable` handles
    /// only; the session itself stays inside its task.
    private struct CaptureState {
        /// The running session task's signal stream, while started.
        /// Finishing it is what `stop()` does; the task tears the session
        /// down when the stream ends.
        var sessionSignal: AsyncStream<SessionSignal>.Continuation?

        /// The single active frame continuation, while a consumer is
        /// attached.
        var continuation: AsyncStream<CapturedFrame>.Continuation?
    }

    /// What the session task waits on: one merged stream rather than one
    /// stream per source, so a single `for await` loop owns the whole
    /// lifecycle — a stream consumed by a cancelled race is finished by that
    /// cancellation, which is exactly the trap two phases of consumers would
    /// fall into.
    enum SessionSignal: Sendable {
        /// The first frame reached the delegate — the proof the capture
        /// path is alive.
        case firstFrame

        /// The verification window elapsed with no frame delivered.
        case verificationTimedOut

        /// AVFoundation reported a runtime error; the string is its
        /// description.
        case runtimeError(String)
    }

    /// How long the session has, after `startRunning()` returns, to deliver
    /// its first frame before the start is reported as rejected.
    ///
    /// Generous on purpose: a Continuity Camera wakes an iPhone and
    /// negotiates a format before its first frame, and with four sessions
    /// starting at once that took 5.05 seconds on 2026-09-06 — a five-second
    /// window passed it only because the timer starts after `startRunning()`
    /// returns. A false rejection of a working camera is worse than the wait,
    /// and the wait is cheap: a device that has genuinely failed reports a
    /// runtime error within milliseconds and never reaches the window, and
    /// a device that is merely silent (a built-in camera behind a closed lid)
    /// is remembered by the engine and not retried on every pass, so the
    /// window is paid once per change rather than once per pass.
    static let frameVerificationWindow = Duration.seconds(10)

    /// Creates a camera input over a discovered device.
    ///
    /// - Parameters:
    ///   - device: The discovered camera.
    ///   - eventBus: The host's event bus, for capture diagnostics. Omit it
    ///     in tests that assert only on the thrown errors.
    ///   - requestAuthorization: The authorization seam; defaults to the
    ///     real TCC request.
    init(
        device: CaptureDevice,
        eventBus: EventBus? = nil,
        requestAuthorization: @escaping @Sendable () async -> Bool = CameraInput.requestCameraAccess
    ) {
        self.device = device
        self.eventBus = eventBus
        self.requestAuthorization = requestAuthorization
    }

    /// The stable identifier — the device's unique ID, verbatim, so
    /// `devices --json` output works as a selector across launches.
    var id: InputID { InputID(rawValue: device.uniqueID) }

    /// The user-facing device name.
    var name: String { device.name }

    /// A camera.
    var kind: InputKind { device.kind }

    /// A camera produces video only; its audio stream stays the seam's
    /// already-finished default.
    var media: InputMedia { .video }

    /// Requests authorization and starts the capture session task, returning
    /// only once the session has delivered its first frame.
    ///
    /// Throws ``CaptureInputError/authorizationDenied(_:_:)`` when TCC
    /// denies camera access, ``CaptureInputError/deviceUnavailable(_:)``
    /// when the device has disconnected since discovery, and
    /// ``CaptureInputError/configurationRejected(_:_:)`` when the session
    /// cannot accept the device or output or reports a runtime error before
    /// its first frame, and ``CaptureInputError/startedSilent(_:within:)``
    /// when it delivers no frame within ``frameVerificationWindow`` — the
    /// honest-start gate described on the type. On any throw the session is
    /// torn down before returning, so a
    /// rejected start leaves nothing running and no indicator light on.
    /// Device disconnection after a successful start is a normal event,
    /// never an error; a session that reports a runtime error after a
    /// successful start is reported on the bus as an `input.runtimeError`
    /// error event, torn down, and its frame stream finished.
    func start() async throws {
        guard await requestAuthorization() else {
            throw CaptureInputError.authorizationDenied(.camera, id)
        }

        let (signals, signal) = AsyncStream.makeStream(of: SessionSignal.self)
        let device = self.device
        let inputID = id
        let inputName = name
        let eventBus = self.eventBus
        // The first delivery is the proof of life; every later one is only
        // a frame. The flag is a mutex rather than an atomic because an
        // escaping closure captures it, and it is uncontended — the delegate
        // queue is the sole caller.
        let delivered = Mutex(false)
        let deliver: @Sendable (CapturedFrame) -> Void = { [weak self] frame in
            let isFirst = delivered.withLock { flag in
                defer { flag = true }
                return !flag
            }
            if isFirst { signal.yield(.firstFrame) }
            self?.state.withLock { $0.continuation }?.yield(frame)
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            Task { [weak self] in
                let running: RunningSession
                do {
                    running = try Self.makeRunningSession(
                        for: device,
                        id: inputID,
                        deliver: deliver,
                        signal: signal
                    )
                } catch {
                    ready.resume(throwing: error)
                    return
                }
                let verification = Task {
                    try? await Task.sleep(for: Self.frameVerificationWindow)
                    guard !Task.isCancelled else { return }
                    signal.yield(.verificationTimedOut)
                }
                defer { verification.cancel() }
                var isReady = false
                // One loop owns the whole lifecycle: the verification race
                // first, then the park until `stop()` finishes the stream or
                // the session reports a runtime error. The session and
                // delegate stay alive and task-confined throughout.
                for await event in signals {
                    switch event {
                    case .firstFrame:
                        guard !isReady else { continue }
                        isReady = true
                        verification.cancel()
                        ready.resume()
                    case .verificationTimedOut:
                        guard !isReady else { continue }
                        running.tearDown()
                        ready.resume(
                            throwing: CaptureInputError.startedSilent(inputID, within: Self.frameVerificationWindow))
                        return
                    case .runtimeError(let reason):
                        running.tearDown()
                        guard isReady else {
                            ready.resume(
                                throwing: CaptureInputError.configurationRejected(
                                    inputID, "the session reported a runtime error before its first frame: \(reason)"
                                ))
                            return
                        }
                        // Post-start, the failure is the session's, not the
                        // start's: report it, release the device, and end
                        // the frame stream so a consumer sees the input
                        // stop rather than a frozen last frame.
                        eventBus?.error(
                            "input.runtimeError",
                            domain: .capture,
                            params: [
                                "id": .string(inputID.rawValue),
                                "name": .string(inputName),
                                "error": .string(reason),
                            ]
                        )
                        await self?.stop()
                        return
                    }
                }
                running.tearDown()
            }
        }
        state.withLock { $0.sessionSignal = signal }
    }

    /// The stream of captured frames. One consumer at a time: a new call
    /// finishes the previous stream and takes over, per the frame
    /// ownership rule.
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

    /// Ends the session task and finishes the frame stream. Safe to call
    /// more than once.
    func stop() async {
        let (sessionSignal, continuation) = state.withLock { state in
            let pair = (state.sessionSignal, state.continuation)
            state.sessionSignal = nil
            state.continuation = nil
            return pair
        }
        sessionSignal?.finish()
        continuation?.finish()
    }

    /// A running capture session with everything that must live and die with
    /// it: the delegate the output delivers through, and the runtime error
    /// observer that keeps the session honest after its start.
    ///
    /// Confined to the session task; never crosses an isolation boundary.
    private struct RunningSession {
        /// The capture session.
        let session: AVCaptureSession

        /// The delegate the video data output delivers through, held so it
        /// outlives the configuration call that created it.
        let delegate: CameraFrameDelegate

        /// The runtime error observer, registered for the session's lifetime.
        let observer: any NSObjectProtocol

        /// Stops the session and releases the observer and delegate.
        func tearDown() {
            session.stopRunning()
            NotificationCenter.default.removeObserver(observer)
            withExtendedLifetime(delegate) {}
        }
    }

    /// Builds, configures, and starts the capture session for a device.
    /// Called from (and its results confined to) the session task.
    ///
    /// - Parameters:
    ///   - device: The discovered camera to capture from.
    ///   - id: The input's identifier, for error reporting.
    ///   - deliver: Called with each captured frame.
    ///   - signal: Where the session's runtime errors are reported, for the
    ///     session's whole lifetime — before the first frame they reject the
    ///     start; after it they end the session.
    /// - Returns: The running session with its delegate and observer.
    private static func makeRunningSession(
        for device: CaptureDevice,
        id: InputID,
        deliver: @escaping @Sendable (CapturedFrame) -> Void,
        signal: AsyncStream<SessionSignal>.Continuation
    ) throws -> RunningSession {
        guard let captureDevice = AVCaptureDevice(uniqueID: device.uniqueID) else {
            throw CaptureInputError.deviceUnavailable(id)
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: captureDevice)
        guard session.canAddInput(input) else {
            throw CaptureInputError.configurationRejected(id, "the session did not accept the device input")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        // Normalize once, at the input: AVFoundation converts camera-native
        // formats ('420v'/'420f') to the working format here, and its BGRA
        // buffers are IOSurface backed.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        let delegate = CameraFrameDelegate(deliver: deliver)
        // The delegate queue is an AVFoundation API requirement, not
        // concurrency design: the callback immediately crosses into the
        // AsyncStream, and no other code runs on it.
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.moonwink.tingra.capture.camera"))
        guard session.canAddOutput(output) else {
            throw CaptureInputError.configurationRejected(id, "the session did not accept the video data output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        // `startRunning()` neither throws nor returns a status — a failure
        // (e.g. the device already in use by another application) shows up
        // as `isRunning` staying false, or as a runtime error notification
        // carrying the real reason, posted *after* this call has returned.
        // The observer therefore lives as long as the session does: it is
        // what turns a graph that never came up into a rejected start, and a
        // device that dies mid-show into a reported, released input, instead
        // of either silently reporting success (CLAUDE.md: never silently
        // succeed; provide a detailed, developer facing message).
        let observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            signal.yield(.runtimeError(error?.localizedDescription ?? "AVFoundation gave no reason"))
        }

        session.startRunning()
        guard session.isRunning else {
            NotificationCenter.default.removeObserver(observer)
            throw CaptureInputError.configurationRejected(
                id, "the session did not start running: the device may already be in use by another application")
        }
        return RunningSession(session: session, delegate: delegate, observer: observer)
    }

    /// The production authorization seam: asks TCC for camera access
    /// (prompting on first use).
    private static let requestCameraAccess: @Sendable () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

/// Bridges AVFoundation's delegate callback into the frame stream. Confined
/// to the session's delegate queue; each delivered buffer is tagged if the
/// framework left it untagged, keeps its host clock PTS, and leaves through
/// `deliver` — transferring ownership at the yield, per the frame ownership
/// rule.
private final class CameraFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Hands one normalized frame to the input's live stream.
    private let deliver: @Sendable (CapturedFrame) -> Void

    /// Creates a delegate delivering frames through the given closure.
    init(deliver: @escaping @Sendable (CapturedFrame) -> Void) {
        self.deliver = deliver
    }

    /// Normalizes and forwards one captured sample buffer.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        FrameNormalization.tagBT709IfUntagged(pixelBuffer)
        deliver(
            CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
        )
    }
}
