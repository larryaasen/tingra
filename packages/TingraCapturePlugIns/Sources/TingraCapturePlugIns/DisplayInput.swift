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
/// Concurrency: the non-`Sendable` stream and output live entirely inside
/// one session task that `start()` spawns and `stop()` signals — they never
/// cross an isolation boundary, so the input needs no `@unchecked Sendable`
/// (the frame ownership rule covers the frames themselves). The capture
/// machinery is a hardware path: it gets this seam, not unit tests; the
/// injected authorization check keeps the denied path testable without the
/// Screen Recording TCC prompt (CLAUDE.md, Testing).
final class DisplayInput: Input, Sendable {
    /// The discovered display this input captures from.
    private let display: DisplayDevice

    /// Requests Screen Recording authorization, returning whether access is
    /// granted. Production asks ScreenCaptureKit
    /// (`SCShareableContent.current` succeeds only once granted); tests
    /// inject a fixed answer.
    private let requestAuthorization: @Sendable () async -> Bool

    /// The stop signal for the running session task and the single active
    /// frame continuation. One holder at a time, per the frame ownership
    /// rule (ARCHITECTURE.md): a new `frames()` call finishes and replaces
    /// the previous stream.
    private let state = Mutex<CaptureState>(CaptureState())

    /// The mutable capture state behind the mutex — `Sendable` handles
    /// only; the stream itself stays inside its task.
    private struct CaptureState {
        /// Finishing this ends the session task, while started.
        var stopSignal: AsyncStream<Never>.Continuation?

        /// The single active frame continuation, while a consumer is
        /// attached.
        var continuation: AsyncStream<CapturedFrame>.Continuation?
    }

    /// Creates a display input over a discovered display.
    ///
    /// - Parameters:
    ///   - display: The discovered display.
    ///   - requestAuthorization: The authorization seam; defaults to the
    ///     real Screen Recording check.
    init(
        display: DisplayDevice,
        requestAuthorization: @escaping @Sendable () async -> Bool = DisplayInput.requestScreenRecordingAccess
    ) {
        self.display = display
        self.requestAuthorization = requestAuthorization
    }

    /// The stable identifier — the display's UUID, verbatim, so a resolved
    /// display selection survives reconnection.
    var id: InputID { InputID(rawValue: display.uniqueID) }

    /// The user-facing display name.
    var name: String { display.name }

    /// A display.
    var kind: InputKind { .display }

    /// Requests authorization and starts the capture stream task.
    ///
    /// Throws ``CaptureInputError/authorizationDenied(_:_:)`` when Screen
    /// Recording access is denied, ``CaptureInputError/deviceUnavailable(_:)``
    /// when the display has disconnected since discovery, and
    /// ``CaptureInputError/configurationRejected(_:_:)`` when ScreenCaptureKit
    /// cannot start the stream. Display disconnection after a successful
    /// start is a normal event, never an error.
    func start() async throws {
        guard await requestAuthorization() else {
            throw CaptureInputError.authorizationDenied(.display, id)
        }

        let (stopSignal, stopContinuation) = AsyncStream.makeStream(of: Never.self)
        let display = self.display
        let inputID = id
        let deliver: @Sendable (CapturedFrame) -> Void = { [weak self] frame in
            self?.state.withLock { $0.continuation }?.yield(frame)
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            Task {
                let stream: SCStream
                do {
                    stream = try await Self.makeRunningStream(for: display, id: inputID, deliver: deliver)
                } catch {
                    ready.resume(throwing: error)
                    return
                }
                ready.resume()
                // Park until stop() finishes the signal (or the task is
                // cancelled); the stream and its output stay alive and
                // task-confined for the duration — never crossing an
                // isolation boundary, so no `@unchecked Sendable` is needed.
                for await _ in stopSignal {}
                try? await stream.stopCapture()
            }
        }
        state.withLock { $0.stopSignal = stopContinuation }
    }

    /// The stream of captured frames. One consumer at a time: a new call
    /// finishes the previous stream and takes over, per the frame ownership
    /// rule.
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

    /// Ends the session task (which stops the capture stream) and finishes
    /// the frame stream. Safe to call more than once.
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

    /// Builds, configures, and starts the capture stream for a display.
    ///
    /// Resolves the display's current `CGDirectDisplayID` from its stable
    /// UUID (the ID changes across reconnects; the UUID does not), matches
    /// it against ScreenCaptureKit's shareable content, and starts an
    /// `SCStream` delivering 32BGRA frames at native pixel size.
    private static func makeRunningStream(
        for display: DisplayDevice,
        id: InputID,
        deliver: @escaping @Sendable (CapturedFrame) -> Void
    ) async throws -> SCStream {
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

        let output = DisplayStreamOutput(deliver: deliver)
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
        return stream
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
/// absorbs stream-stop errors as the normal events they are (a display
/// disconnecting is not a failure). Confined to the stream's sample-handler
/// queue; each delivered buffer is tagged if the framework left it
/// untagged, keeps its host clock PTS, and leaves through `deliver` —
/// transferring ownership at the yield, per the frame ownership rule.
private final class DisplayStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Hands one normalized frame to the input's live stream.
    private let deliver: @Sendable (CapturedFrame) -> Void

    /// Creates an output delivering frames through the given closure.
    init(deliver: @escaping @Sendable (CapturedFrame) -> Void) {
        self.deliver = deliver
    }

    /// Normalizes and forwards one captured sample buffer, skipping the
    /// idle/blank frames ScreenCaptureKit emits when the screen is
    /// unchanged (only `.complete` frames carry new pixels).
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, Self.isComplete(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        FrameNormalization.tagBT709IfUntagged(pixelBuffer)
        deliver(
            CapturedFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
        )
    }

    /// A display disconnecting or the stream stopping is a normal event, not
    /// an error (CLAUDE.md, Data Flow Rules): the frame stream simply goes
    /// quiet, and the tick re-sends the last frame until the shot changes.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {}

    /// Whether the sample buffer is a complete frame with new pixels, read
    /// from ScreenCaptureKit's per-frame status attachment.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw)
        else { return false }
        return status == .complete
    }
}
