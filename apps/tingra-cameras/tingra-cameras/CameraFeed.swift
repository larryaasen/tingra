//
//  CameraFeed.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// One window's way into the engine: the camera the window shows, drawn in
/// the window's preview, with that camera's controls and the size of its
/// frames.
///
/// Made by ``CaptureEngine/makeFeed()``, one per window, so each window can
/// show a different camera. The feed chooses the camera; the engine runs it
/// (``RunningCamera``), sharing it with any other window showing the same
/// one. The view layer still sees only a frame sink and the callbacks below,
/// never the `Input` seam.
@MainActor
final class CameraFeed {
    /// The engine running the cameras. Weak, because the engine outlives
    /// every feed and a feed must never keep it alive.
    private weak var engine: CaptureEngine?

    /// The feed's identity as a camera's subscriber.
    private var subscriberID: ObjectIdentifier { ObjectIdentifier(self) }

    /// One preview's frame sink: how to draw a frame in it and how to clear
    /// it.
    private struct PreviewSink {
        /// Draws one captured frame in the preview.
        let render: @MainActor (CapturedFrame) -> Void
        /// Drops any displayed frame, called when switching cameras so the
        /// previous camera's last frame does not linger.
        let flush: @MainActor () -> Void
    }

    /// The window's previews, keyed by their views — normally the one; a
    /// preview being replaced and its replacement can overlap for a moment.
    private var previewSinks: [ObjectIdentifier: PreviewSink] = [:]

    /// The camera the feed has subscribed to, showing or still starting, or
    /// nil. Set before subscribing, so a switch that is superseded mid-start
    /// is still unsubscribed by the switch after it.
    private var subscribedCameraID: Device.ID?

    /// The camera input whose frames are showing, or nil before its first
    /// frame or with no camera.
    private var currentInput: (any Input)?

    /// The newest frame the camera delivered, kept so Copy can put the
    /// picture on the pasteboard; nil when no camera is showing. The running
    /// camera holds the same frame, so this pins no extra buffer.
    private var latestFrame: CapturedFrame?

    /// The size of the frames the camera is delivering, or nil before its
    /// first frame. Compared on each frame so a change in size is reported
    /// once, never per frame.
    private var frameDimensions: PixelDimensions?

    /// The camera switch in flight: leaving the previous camera and showing
    /// the selected one. A newer selection cancels it and waits for it to
    /// settle before showing its own camera, so only the latest choice ever
    /// reaches the preview — a slow or silent camera's start can no longer
    /// finish late and overwrite the camera the operator picked since.
    private var switchTask: Task<Void, Never>?

    /// The selected camera whose controls the panel adjusts, or nil when no
    /// camera is selected. Set as soon as a switch resolves the camera —
    /// before it starts, because a camera's controls work whether or not it
    /// is capturing.
    private var controlledInput: (any Input)?

    /// The latest parameter write in flight. Each write waits for the one
    /// before it, so the camera receives them in the order the operator
    /// made them.
    private var parameterTask: Task<Void, Never>?

    /// Reports a user-facing preview error (authorization denied, device
    /// unavailable), or `nil` once the camera is showing again.
    var onPreviewError: (@MainActor (String?) -> Void)?

    /// Reports the selected camera's adjustable controls and their current
    /// values — empty when no camera is selected or it has none (docs/UVC.md,
    /// "The Tingra Cameras controls panel") — including values another
    /// window showing the same camera changed.
    var onCameraParametersChanged: (@MainActor (_ parameters: [Parameter], _ values: [String: JSONValue]) -> Void)?

    /// Reports the size of the frames the camera delivers when it first
    /// shows and whenever it changes, or nil when no camera is showing — the
    /// status bar's resolution reading.
    var onFrameDimensionsChanged: (@MainActor (PixelDimensions?) -> Void)?

    /// Creates a feed showing no camera.
    ///
    /// - Parameter engine: The engine running the cameras.
    init(engine: CaptureEngine) {
        self.engine = engine
    }

    /// Adds a preview to the set the camera's frames are drawn in, showing
    /// it the newest frame straight away so a preview added mid-stream is not
    /// blank until the next one arrives.
    ///
    /// - Parameters:
    ///   - id: The preview's identity, used to remove it again.
    ///   - render: Draws one captured frame in the preview.
    ///   - flush: Clears any displayed frame.
    func addPreviewSink(
        id: ObjectIdentifier,
        render: @escaping @MainActor (CapturedFrame) -> Void,
        flush: @escaping @MainActor () -> Void
    ) {
        previewSinks[id] = PreviewSink(render: render, flush: flush)
        if let latestFrame {
            render(latestFrame)
        }
    }

    /// Removes a preview from the set, when its view goes away.
    ///
    /// - Parameter id: The identity the preview was added under.
    func removePreviewSink(id: ObjectIdentifier) {
        previewSinks[id] = nil
    }

    /// Shows the camera with the given identifier in the window's preview,
    /// leaving whichever camera it showed before — which keeps running for
    /// any other window still showing it.
    ///
    /// Passing `nil` (or an identifier no longer registered) shows no
    /// camera. Authorization denial and device unavailability surface
    /// through ``onPreviewError`` rather than crashing (CLAUDE.md,
    /// never-crash rule).
    ///
    /// The latest call wins: a camera still starting when another is chosen
    /// — a built-in camera behind a closed lid waits out the input's whole
    /// verification window before it reports itself silent — is left, and
    /// its outcome never reaches the preview.
    ///
    /// - Parameters:
    ///   - id: The selected camera's identifier, or `nil` to show none.
    ///   - values: Control values to write to the camera before its controls
    ///     are read and shown — a recalled camera preset's — or nil to leave
    ///     the camera's own values.
    func showCamera(id: Device.ID?, applying values: [String: JSONValue]? = nil) async {
        let previousSwitch = switchTask
        previousSwitch?.cancel()
        let currentSwitch = Task { [weak self] in
            // Let the superseded switch settle first, so it never subscribes
            // after this one has torn down.
            await previousSwitch?.value
            guard !Task.isCancelled else { return }
            await self?.switchCamera(to: id, applying: values)
        }
        switchTask = currentSwitch
        await currentSwitch.value
    }

    /// Leaves the camera showing now and shows the given one, the body of a
    /// single switch. Runs inside ``switchTask``, whose cancellation means a
    /// newer selection has superseded this one.
    ///
    /// - Parameters:
    ///   - id: The camera to show, or `nil` to show none.
    ///   - values: Control values to write before the controls are read, or
    ///     nil.
    private func switchCamera(to id: Device.ID?, applying values: [String: JSONValue]?) async {
        await leaveCamera()
        guard let engine, let id, let input = await engine.cameraInput(withID: id) else { return }

        // A preset's values go in before the controls are read, so the panel
        // shows what the camera holds once they are written — the camera
        // takes them whether or not it is capturing.
        if let values {
            await input.setParameters(values)
            guard !Task.isCancelled else { return }
            engine.cameraParametersChanged(values, of: id, by: subscriberID)
        }

        // Show the camera's controls while it starts: they adjust the camera
        // whether or not it is capturing, and a slow start should not hide
        // them.
        await showControls(of: input)
        guard !Task.isCancelled else { return }

        subscribedCameraID = id
        let subscriber = CameraSubscriber(
            id: subscriberID,
            onFrame: { [weak self] frame in self?.present(frame) },
            onParameters: { [weak self] values in self?.receiveParameters(values, of: id) }
        )
        do {
            try await engine.subscribe(subscriber, to: input)
        } catch is CancellationError {
            // A newer selection superseded this one; it leaves this camera
            // and reports its own outcome.
            return
        } catch {
            // The engine has already reported the failure on the bus; the
            // preview belongs to a newer selection if there is one.
            guard !Task.isCancelled else { return }
            onPreviewError?(CaptureEngine.message(for: error))
            return
        }
        guard !Task.isCancelled else { return }
        currentInput = input
        onPreviewError?(nil)
    }

    /// Leaves the camera the feed shows or is starting, clears the preview,
    /// and reports that nothing is showing.
    private func leaveCamera() async {
        currentInput = nil
        if let previous = subscribedCameraID {
            subscribedCameraID = nil
            await engine?.unsubscribe(subscriberID, from: previous)
        }
        for sink in previewSinks.values {
            sink.flush()
        }
        latestFrame = nil
        frameDimensions = nil
        onFrameDimensionsChanged?(nil)
        controlledInput = nil
        onCameraParametersChanged?([], [:])
    }

    /// Draws a frame in the window's previews, keeps it for Copy, and
    /// reports its size when that differs from the last frame's.
    ///
    /// - Parameter frame: The newest frame from the camera.
    private func present(_ frame: CapturedFrame) {
        latestFrame = frame
        let dimensions = PixelDimensions(
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        if dimensions != frameDimensions {
            frameDimensions = dimensions
            onFrameDimensionsChanged?(dimensions)
        }
        for sink in previewSinks.values {
            sink.render(frame)
        }
    }

    /// Shows control values another window wrote to the same camera.
    ///
    /// - Parameters:
    ///   - values: The camera's control values now.
    ///   - cameraID: The camera they are for.
    private func receiveParameters(_ values: [String: JSONValue], of cameraID: Device.ID) {
        guard let input = controlledInput, input.id.rawValue == cameraID else { return }
        onCameraParametersChanged?(input.parameters, values)
    }

    /// Reads a camera's controls and current values and reports them, unless
    /// a newer selection has superseded this switch meanwhile.
    ///
    /// - Parameter input: The selected camera.
    private func showControls(of input: any Input) async {
        let values = await input.currentParameters()
        guard !Task.isCancelled else { return }
        controlledInput = input
        onCameraParametersChanged?(input.parameters, values)
    }

    /// Writes the selected camera's control values — the panel's whole
    /// payload, of which the camera writes only what changed — after any
    /// write still in flight, and shows them in every other window showing
    /// the camera.
    ///
    /// - Parameters:
    ///   - values: Every control's value, keyed by parameter.
    ///   - refreshing: Whether to read the camera's values back afterwards
    ///     and report them: true after an Auto switch flips, because the
    ///     values it governs are the camera's again (an exposure time chosen
    ///     under Auto Exposure becomes the manual starting point). A response
    ///     to the operator's action, never a poll.
    func setCameraParameters(_ values: [String: JSONValue], refreshing: Bool) {
        guard let input = controlledInput else { return }
        let cameraID = input.id.rawValue
        let previous = parameterTask
        parameterTask = Task { [weak self] in
            await previous?.value
            await input.setParameters(values)
            guard refreshing else {
                guard let self else { return }
                self.engine?.cameraParametersChanged(values, of: cameraID, by: self.subscriberID)
                return
            }
            let fresh = await input.currentParameters()
            guard let self else { return }
            self.engine?.cameraParametersChanged(fresh, of: cameraID, by: self.subscriberID)
            guard self.controlledInput?.id == input.id else { return }
            self.onCameraParametersChanged?(input.parameters, fresh)
        }
    }

    /// Writes control values to a camera that is already selected — a
    /// recalled camera preset's — once any switch in flight has settled,
    /// then reads the camera's values back and reports them. Dropped when a
    /// different camera has been selected meanwhile, so one camera's preset
    /// never reaches another.
    ///
    /// - Parameters:
    ///   - values: The control values, keyed by parameter.
    ///   - id: The camera they are for.
    func applyCameraParameters(_ values: [String: JSONValue], toCamera id: Device.ID) async {
        await switchTask?.value
        guard controlledInput?.id.rawValue == id else { return }
        setCameraParameters(values, refreshing: true)
        await parameterTask?.value
    }

    /// Puts the camera's newest frame on the general pasteboard as an image,
    /// at the camera's full resolution and without the preview's cross bars,
    /// reporting a `preview.copied` event — or a `preview.copy` error when
    /// there is no frame to copy or it cannot be converted.
    func copyCurrentFrame() {
        guard let frame = latestFrame, let input = currentInput else {
            engine?.eventBus.error(
                "preview.copy",
                domain: .capture,
                params: ["error": .string("No camera frame to copy: no camera is showing yet.")]
            )
            return
        }
        guard let image = FrameClipboard.image(from: frame.pixelBuffer) else {
            engine?.eventBus.error(
                "preview.copy",
                domain: .capture,
                params: [
                    "id": .string(input.id.rawValue),
                    "error": .string("The camera frame could not be converted to an image."),
                ]
            )
            return
        }
        FrameClipboard.copy(image)
        engine?.eventBus.event(
            "preview.copied",
            domain: .capture,
            params: [
                "id": .string(input.id.rawValue),
                "width": .int(image.width),
                "height": .int(image.height),
            ]
        )
    }

    /// Leaves the camera, e.g. when the window closes; the camera keeps
    /// running for any other window showing it. Safe to call more than once.
    func stop() async {
        // Settle any switch in flight first, so a camera still starting
        // cannot come up after the window has gone.
        switchTask?.cancel()
        await switchTask?.value
        switchTask = nil
        await leaveCamera()
    }
}

/// One feed's handlers on a running camera: where its frames go and how it
/// hears of control values another window wrote.
struct CameraSubscriber {
    /// The feed's identity.
    let id: ObjectIdentifier

    /// Draws one of the camera's frames in the feed's window.
    let onFrame: @MainActor (CapturedFrame) -> Void

    /// Shows control values another window wrote to the camera.
    let onParameters: @MainActor ([String: JSONValue]) -> Void
}

/// A camera at least one window is showing or starting: its input, started
/// once however many windows show it, and those windows' handlers.
///
/// A camera input has one frame consumer at a time (the frame ownership
/// rule), so windows showing the same camera cannot each pull its frames;
/// the engine pulls them once here and draws each in every window.
@MainActor
final class RunningCamera {
    /// Where the camera stands.
    enum State {
        /// Starting: windows wait for the first frame.
        case starting
        /// Delivering frames.
        case running
        /// Its start was cancelled or failed; it delivers nothing.
        case stopped
    }

    /// The camera's input.
    let input: any Input

    /// Where the camera stands.
    var state = State.starting

    /// The windows showing the camera, by feed.
    var subscribers: [ObjectIdentifier: CameraSubscriber] = [:]

    /// The windows waiting for the camera's start to finish, resumed with
    /// its outcome.
    var waiters: [ObjectIdentifier: CheckedContinuation<Void, any Error>] = [:]

    /// The task starting the camera and, once it is up, its frame fan-out.
    var startTask: Task<Void, Never>?

    /// The task pulling the camera's frames and drawing them in every
    /// window.
    var frameTask: Task<Void, Never>?

    /// The newest frame, handed to a window that starts showing the camera
    /// while it runs.
    private(set) var latestFrame: CapturedFrame?

    /// Whether the camera is still starting.
    var isStarting: Bool { state == .starting }

    /// Whether the camera is delivering frames.
    var isRunning: Bool { state == .running }

    /// Creates a camera about to start.
    ///
    /// - Parameter input: The camera's input.
    init(input: any Input) {
        self.input = input
    }

    /// Draws a frame in every window showing the camera, keeping it for a
    /// window that arrives later.
    ///
    /// - Parameter frame: The camera's newest frame.
    func present(_ frame: CapturedFrame) {
        latestFrame = frame
        for subscriber in subscribers.values {
            subscriber.onFrame(frame)
        }
    }

    /// Tells every window waiting for the start how it went.
    ///
    /// - Parameter error: Why the start failed, or nil when the camera is
    ///   delivering.
    func resumeWaiters(throwing error: (any Error)?) {
        let waiting = waiters
        waiters = [:]
        for continuation in waiting.values {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}
