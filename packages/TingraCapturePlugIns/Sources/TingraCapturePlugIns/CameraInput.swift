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
final class CameraInput: Input, Sendable {
    /// The discovered device this input captures from.
    private let device: CaptureDevice

    /// Requests camera authorization, returning whether access is granted.
    /// Production asks TCC via `AVCaptureDevice.requestAccess`; tests
    /// inject a fixed answer.
    private let requestAuthorization: @Sendable () async -> Bool

    /// The stop signal for the running session task and the single active
    /// frame continuation. One holder at a time, per the frame ownership
    /// rule (ARCHITECTURE.md): a new `frames()` call finishes and replaces
    /// the previous stream.
    private let state = Mutex<CaptureState>(CaptureState())

    /// The mutable capture state behind the mutex — `Sendable` handles
    /// only; the session itself stays inside its task.
    private struct CaptureState {
        /// Finishing this ends the session task, while started.
        var stopSignal: AsyncStream<Never>.Continuation?

        /// The single active frame continuation, while a consumer is
        /// attached.
        var continuation: AsyncStream<CapturedFrame>.Continuation?
    }

    /// Creates a camera input over a discovered device.
    ///
    /// - Parameters:
    ///   - device: The discovered camera.
    ///   - requestAuthorization: The authorization seam; defaults to the
    ///     real TCC request.
    init(
        device: CaptureDevice,
        requestAuthorization: @escaping @Sendable () async -> Bool = CameraInput.requestCameraAccess
    ) {
        self.device = device
        self.requestAuthorization = requestAuthorization
    }

    /// The stable identifier — the device's unique ID, verbatim, so
    /// `devices --json` output works as a selector across launches.
    var id: InputID { InputID(rawValue: device.uniqueID) }

    /// The user-facing device name.
    var name: String { device.name }

    /// A camera.
    var kind: InputKind { device.kind }

    /// Requests authorization and starts the capture session task.
    ///
    /// Throws ``CaptureInputError/authorizationDenied(_:_:)`` when TCC
    /// denies camera access, ``CaptureInputError/deviceUnavailable(_:)``
    /// when the device has disconnected since discovery, and
    /// ``CaptureInputError/configurationRejected(_:_:)`` when the session
    /// cannot accept the device or output. Device disconnection after a
    /// successful start is a normal event, never an error.
    func start() async throws {
        guard await requestAuthorization() else {
            throw CaptureInputError.authorizationDenied(.camera, id)
        }

        let (stopSignal, stopContinuation) = AsyncStream.makeStream(of: Never.self)
        let device = self.device
        let inputID = id
        let deliver: @Sendable (CapturedFrame) -> Void = { [weak self] frame in
            self?.state.withLock { $0.continuation }?.yield(frame)
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            Task {
                let session: AVCaptureSession
                let delegate: CameraFrameDelegate
                do {
                    (session, delegate) = try Self.makeRunningSession(
                        for: device,
                        id: inputID,
                        deliver: deliver
                    )
                } catch {
                    ready.resume(throwing: error)
                    return
                }
                ready.resume()
                // Park until stop() finishes the signal (or the task is
                // cancelled); the session and delegate stay alive and
                // task-confined for the duration.
                for await _ in stopSignal {}
                session.stopRunning()
                withExtendedLifetime(delegate) {}
            }
        }
        state.withLock { $0.stopSignal = stopContinuation }
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
        let (stopSignal, continuation) = state.withLock { state in
            let pair = (state.stopSignal, state.continuation)
            state.stopSignal = nil
            state.continuation = nil
            return pair
        }
        stopSignal?.finish()
        continuation?.finish()
    }

    /// Builds, configures, and starts the capture session for a device.
    /// Called from (and its results confined to) the session task.
    private static func makeRunningSession(
        for device: CaptureDevice,
        id: InputID,
        deliver: @escaping @Sendable (CapturedFrame) -> Void
    ) throws -> (AVCaptureSession, CameraFrameDelegate) {
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
        session.startRunning()
        return (session, delegate)
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
