//
//  CameraSession.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// One window's camera: which camera the window shows, how its preview
/// stands, and that camera's controls — so each window can show a different
/// camera.
///
/// The app-wide state — the connected cameras, the presets, the permissions,
/// the cross bars — stays in the shared ``HardwareModel``; everything that
/// belongs to the camera a window shows is here. Each window owns one
/// (``WindowSession``), reached by its views through the environment and by
/// the menu bar through the key window's focused scene value. It reaches the
/// engine through its own ``CameraFeed``, so two windows showing the same
/// camera share it and two showing different cameras run both.
@MainActor
@Observable
final class CameraSession {
    /// The shared model: the cameras to choose from, the presets, and the
    /// engine. Nil until the window starts the session.
    private(set) var model: HardwareModel?

    /// The window's way into the engine, or nil before the session starts
    /// and in Xcode previews, which open no camera.
    @ObservationIgnored private var feed: CameraFeed?

    /// The identifier of the camera the window shows, or `nil` if none is
    /// selected. Drives the sidebar highlight and the preview feed.
    private(set) var selectedCameraID: Device.ID?

    /// A short, user-facing message describing why the live preview cannot be
    /// shown (authorization denied, device unavailable), or `nil` when the
    /// preview is healthy. Surfaced by the preview canvas.
    private(set) var previewError: String?

    /// The selected camera's adjustable controls, in display order — empty
    /// when no camera is selected or it has none (a built-in or Continuity
    /// camera). Drawn by the camera controls.
    private(set) var cameraParameters: [Parameter] = []

    /// The selected camera's control values, keyed by parameter — the
    /// camera's own values when it was selected, then the operator's edits,
    /// and any another window showing the same camera made.
    private(set) var cameraParameterValues: [String: JSONValue] = [:]

    /// The size of the frames the selected camera is delivering, or nil
    /// before its first frame — the status bar's resolution reading.
    private(set) var frameDimensions: PixelDimensions?

    /// The unsnapped values a framing gesture has moved to so far, by key.
    /// A drag or pinch moves in small increments; snapping each one to the
    /// camera's step on its own would round it away, so the gesture
    /// accumulates here and only what it sends is snapped. Cleared when the
    /// gesture ends.
    @ObservationIgnored private var framingGestureValues: [String: Double] = [:]

    /// Creates a session showing no camera. Cheap and free of side effects,
    /// because SwiftUI makes one each time a window's root view is
    /// initialized and keeps only the first; nothing starts until
    /// ``start(model:restoringCameraID:name:)``.
    init() {}

    /// The camera the window shows, resolved from ``selectedCameraID``
    /// among the connected cameras, or `nil` when nothing is selected.
    var selectedCamera: Device? {
        guard let selectedCameraID else { return nil }
        return model?.cameras.first { $0.id == selectedCameraID }
    }

    /// Where the selected camera's preview stands, for the status bar.
    var previewState: PreviewState {
        if selectedCamera == nil { return .noCamera }
        if previewError != nil { return .unavailable }
        return frameDimensions == nil ? .starting : .live
    }

    /// Starts the session as its window appears: waits for the cameras to be
    /// discovered, then shows the camera the window opens on
    /// (``HardwareModel/cameraForNewWindow(restoringID:name:)``). Runs once;
    /// a later call does nothing.
    ///
    /// - Parameters:
    ///   - model: The shared model.
    ///   - restoringCameraID: The camera the window showed when it was last
    ///     open, restored by macOS with the window, or nil.
    ///   - name: That camera's name, the fallback when its identifier
    ///     changed because it was plugged into another port.
    func start(model: HardwareModel, restoringCameraID: Device.ID?, name: String?) async {
        guard self.model == nil else { return }
        self.model = model
        await model.start()
        let choice = model.cameraForNewWindow(restoringID: restoringCameraID, name: name)
        guard let feed = model.makeFeed() else {
            // The static preview model opens no camera; it only selects one.
            selectedCameraID = choice?.camera.id
            return
        }
        self.feed = feed
        feed.onPreviewError = { [weak self] message in
            self?.previewError = message
        }
        feed.onCameraParametersChanged = { [weak self] parameters, values in
            self?.cameraParameters = parameters
            self?.cameraParameterValues = values
        }
        feed.onFrameDimensionsChanged = { [weak self] dimensions in
            self?.frameDimensions = dimensions
        }
        model.register(self)
        guard let choice else { return }
        selectedCameraID = choice.camera.id
        Task { await feed.showCamera(id: choice.camera.id, applying: choice.values) }
    }

    /// Leaves the window's camera as the window closes — it keeps running
    /// for any other window showing it — and stops following device and
    /// permission changes.
    func stop() async {
        model?.unregister(self)
        await feed?.stop()
    }

    /// Keeps the selection valid as cameras connect and disconnect: if the
    /// window's camera has disconnected, it falls back to the first
    /// available camera and shows it. A connection is a normal event, never
    /// an error.
    ///
    /// - Parameter cameras: The cameras connected now, in display order.
    func followDevices(_ cameras: [Device]) {
        guard selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) else { return }
        let replacement = cameras.first?.id
        selectedCameraID = replacement
        Task { await feed?.showCamera(id: replacement) }
    }

    /// Restarts the window's camera when the camera permission has just been
    /// granted and the preview was showing why it could not open — so a
    /// grant shows the camera without the operator selecting it again.
    func retryAfterPermissionGrant() {
        guard previewError != nil, let selectedCameraID else { return }
        Task { await feed?.showCamera(id: selectedCameraID) }
    }

    /// Selects a camera and switches the window's preview to it, remembering
    /// it as the camera the next window and launch open. Selecting the
    /// camera already selected restarts it when its preview could not open,
    /// so reselecting it — what the preview's error tells the operator to
    /// do — tries again.
    ///
    /// - Parameters:
    ///   - id: The chosen camera's identifier.
    ///   - tapName: The tap the choosing control reports: the sidebar's row
    ///     by default, the compact window's picker from there.
    func selectCamera(_ id: Device.ID, tapName: String = "cameraSelect.row") {
        // Record the click first, distinct from its effect — even a tap on
        // the already-selected camera is a real click (see EVENTS.md).
        model?.recordCaptureTap(tapName, deviceID: id)
        guard id != selectedCameraID || previewError != nil else { return }
        selectedCameraID = id
        if let camera = model?.cameras.first(where: { $0.id == id }) {
            model?.rememberSelectedCamera(camera)
        }
        Task { await feed?.showCamera(id: id) }
    }

    // MARK: Camera controls

    /// Sets one of the selected camera's controls, live: the panel shows the
    /// value at once and the camera receives it straight away. Flipping an
    /// Auto switch reads the camera's values back, so the values it governs
    /// show what the camera chose.
    ///
    /// - Parameters:
    ///   - value: The control's new payload value.
    ///   - parameter: The control.
    func setCameraParameter(_ value: JSONValue, for parameter: Parameter) {
        guard cameraParameterValues[parameter.key] != value else { return }
        cameraParameterValues[parameter.key] = value
        // A choice is re-read too, so an option the camera rejects doesn't
        // stay showing.
        feed?.setCameraParameters(cameraParameterValues, refreshing: parameter.kind != .number)
    }

    /// Returns one of the selected camera's controls to its default — the
    /// camera's factory setting, as it reported it — recording the tap
    /// first (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter parameter: The control to reset.
    func resetCameraParameter(_ parameter: Parameter) {
        var params: [String: EventValue] = ["key": .string(parameter.key)]
        if let selectedCameraID {
            params["id"] = .string(selectedCameraID)
        }
        model?.recordCaptureTap("cameraParameter.reset", params: params)
        setCameraParameter(.double(parameter.defaultValue), for: parameter)
    }

    /// Records a tap on Reset All Controls or a button of the dialog
    /// confirming it, naming the selected camera.
    ///
    /// - Parameter name: The tap's name.
    func recordResetAllTap(_ name: String) {
        var params: [String: EventValue] = [:]
        if let selectedCameraID {
            params["id"] = .string(selectedCameraID)
        }
        model?.recordCaptureTap(name, params: params)
    }

    /// Returns every one of the selected camera's controls to its default,
    /// recording the confirming tap first. An empty payload is what asks for
    /// that: an omitted key means its default, and the camera input orders
    /// the writes so its Auto switches go first. The camera's values are read
    /// back afterwards, because the values an Auto switch governs are the
    /// camera's own again.
    func resetAllCameraParameters() {
        recordResetAllTap("cameraParameterResetAllConfirm.button")
        framingGestureValues = [:]
        cameraParameterValues = [:]
        feed?.setCameraParameters([:], refreshing: true)
    }

    /// Records a tap on one of the camera's controls, with the control's key
    /// and its value as the tap left it (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameters:
    ///   - name: The dotted tap name, e.g. `cameraParameter.slider`.
    ///   - parameter: The control tapped.
    func recordCameraParameterTap(_ name: String, parameter: Parameter) {
        var params: [String: EventValue] = ["key": .string(parameter.key)]
        if let selectedCameraID {
            params["id"] = .string(selectedCameraID)
        }
        if let isOn = parameter.isOn(in: cameraParameterValues) {
            params["value"] = .bool(isOn)
        } else {
            params["value"] = .double(parameter.value(in: cameraParameterValues))
        }
        model?.recordCaptureTap(name, params: params)
    }

    // MARK: Framing

    /// The payload keys of the camera's framing controls — its pan, tilt,
    /// and zoom — which the app draws as framing (the preview's drag, pinch,
    /// and zoom buttons, and the one-row Framing sliders) rather than as a
    /// row each.
    /// The keys are the camera input's stable parameter names (docs/UVC.md).
    nonisolated enum FramingKey {
        /// The camera's pan, in degrees.
        static let pan = "pan"
        /// The camera's tilt, in degrees.
        static let tilt = "tilt"
        /// The camera's zoom, in its own units.
        static let zoom = "zoom"
        /// All three, in the order they are reset.
        static let all = [pan, tilt, zoom]
    }

    /// The selected camera's control with a key, or nil when it has none.
    ///
    /// - Parameter key: The parameter's payload key.
    /// - Returns: The parameter, or nil.
    func cameraParameter(forKey key: String) -> Parameter? {
        cameraParameters.first { $0.key == key }
    }

    /// Whether the selected camera has any framing control.
    var hasFraming: Bool {
        FramingKey.all.contains { cameraParameter(forKey: $0) != nil }
    }

    /// Sets a framing control to a value, snapped onto the camera's step.
    ///
    /// - Parameters:
    ///   - key: The framing control's key.
    ///   - value: The new value, in the control's display units.
    func setFraming(_ key: String, to value: Double) {
        guard let parameter = cameraParameter(forKey: key) else { return }
        setCameraParameter(.double(parameter.snapped(value)), for: parameter)
    }

    /// Moves a framing control by an amount, as one step of a continuing
    /// gesture — a drag across the preview or a pinch. The movement
    /// accumulates unsnapped, so many small steps add up to the camera's
    /// whole steps.
    ///
    /// - Parameters:
    ///   - key: The framing control's key.
    ///   - delta: The amount to move it, in the control's display units.
    func moveFraming(_ key: String, by delta: Double) {
        guard delta != 0, let parameter = cameraParameter(forKey: key) else { return }
        let start = framingGestureValues[key] ?? parameter.value(in: cameraParameterValues)
        let moved = parameter.clamped(start + delta)
        framingGestureValues[key] = moved
        setCameraParameter(.double(parameter.snapped(moved)), for: parameter)
    }

    /// Ends a framing gesture: forgets its accumulated values and records
    /// its tap with the framing it left (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter name: The dotted tap name, e.g. `cameraFraming.drag`.
    func endFramingGesture(_ name: String) {
        framingGestureValues = [:]
        recordFramingTap(name)
    }

    /// Moves the camera's framing for a drag across the preview, the way
    /// Maps moves its map: the picture follows the pointer, so dragging it
    /// right pans the camera left to bring the left side into view, and
    /// dragging it down tilts the camera up. Dragging the preview's whole
    /// width or height covers the whole pan or tilt range.
    ///
    /// - Parameters:
    ///   - translation: How far the pointer moved, in points, with y
    ///     growing downward (AppKit's mouse delta).
    ///   - viewSize: The preview's size, in points.
    func dragFraming(by translation: CGSize, in viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        if let pan = cameraParameter(forKey: FramingKey.pan) {
            let span = pan.range.upperBound - pan.range.lowerBound
            moveFraming(FramingKey.pan, by: -translation.width / viewSize.width * span)
        }
        if let tilt = cameraParameter(forKey: FramingKey.tilt) {
            let span = tilt.range.upperBound - tilt.range.lowerBound
            moveFraming(FramingKey.tilt, by: translation.height / viewSize.height * span)
        }
    }

    /// Zooms the camera for a pinch or an Option-scroll over the preview.
    ///
    /// - Parameter fraction: How far to zoom, as a fraction of the zoom
    ///   range; positive zooms in.
    func zoomFraming(byFraction fraction: Double) {
        guard let zoom = cameraParameter(forKey: FramingKey.zoom) else { return }
        moveFraming(FramingKey.zoom, by: fraction * (zoom.range.upperBound - zoom.range.lowerBound))
    }

    /// Zooms in or out by a tenth of the zoom range — the preview's zoom
    /// buttons, like Maps' — recording the tap first.
    ///
    /// - Parameter steps: `1` to zoom in, `-1` to zoom out.
    func stepZoom(by steps: Int) {
        recordFramingTap(steps > 0 ? "cameraFraming.zoomIn" : "cameraFraming.zoomOut")
        guard let zoom = cameraParameter(forKey: FramingKey.zoom) else { return }
        let span = zoom.range.upperBound - zoom.range.lowerBound
        let current = zoom.value(in: cameraParameterValues)
        setFraming(FramingKey.zoom, to: current + Double(steps) * span / 10)
    }

    /// Returns the camera's pan, tilt, and zoom to its defaults — the
    /// preview's reset button — recording the tap first.
    func resetFraming() {
        recordFramingTap("cameraFraming.reset")
        framingGestureValues = [:]
        for key in FramingKey.all {
            guard let parameter = cameraParameter(forKey: key) else { continue }
            setCameraParameter(.double(parameter.defaultValue), for: parameter)
        }
    }

    /// Records a framing tap with the pan, tilt, and zoom it left.
    ///
    /// - Parameter name: The dotted tap name.
    private func recordFramingTap(_ name: String) {
        var params: [String: EventValue] = [:]
        if let selectedCameraID {
            params["id"] = .string(selectedCameraID)
        }
        for key in FramingKey.all {
            guard let parameter = cameraParameter(forKey: key) else { continue }
            params[key] = .double(parameter.value(in: cameraParameterValues))
        }
        model?.recordCaptureTap(name, params: params)
    }

    // MARK: Preview

    /// Whether Copy has a live camera frame to copy: a camera is selected
    /// and showing.
    var canCopyFrame: Bool {
        selectedCamera != nil && previewError == nil
    }

    /// Copies the window's camera's current frame to the pasteboard,
    /// recording the tap first (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter source: Where Copy was chosen: `menu` (the Edit menu or
    ///   ⌘C) or `contextMenu` (the preview's context menu).
    func copyFrame(from source: String) {
        model?.recordCaptureTap("previewCopy.\(source)", deviceID: selectedCameraID)
        feed?.copyCurrentFrame()
    }

    /// Connects the window's preview to its camera, so live frames flow
    /// straight to the screen.
    ///
    /// - Parameters:
    ///   - id: The preview's identity, used to disconnect it again.
    ///   - renderFrame: Draws one captured frame in the preview.
    ///   - flush: Clears any displayed frame, used when switching cameras.
    func attachPreview(
        id: ObjectIdentifier,
        renderFrame: @escaping @MainActor (CapturedFrame) -> Void,
        flush: @escaping @MainActor () -> Void
    ) {
        feed?.addPreviewSink(id: id, render: renderFrame, flush: flush)
    }

    /// Disconnects the window's preview when its view goes away, so no
    /// frames are drawn into a torn-down view.
    ///
    /// - Parameter id: The identity the preview attached under.
    func detachPreview(id: ObjectIdentifier) {
        feed?.removePreviewSink(id: id)
    }

    // MARK: Camera presets

    /// Whether there is a camera whose settings a new preset can save: one is
    /// selected.
    var canSavePreset: Bool {
        selectedCamera != nil
    }

    /// Whether a preset can be updated with the window's camera's current
    /// settings: it is that camera's preset.
    ///
    /// - Parameter preset: The preset.
    /// - Returns: Whether Update Preset applies.
    func canUpdatePreset(_ preset: CameraPreset) -> Bool {
        guard let selectedCameraID else { return false }
        return model?.camera(for: preset)?.id == selectedCameraID
    }

    /// Saves the window's camera's settings as a new preset.
    ///
    /// - Parameter name: The operator's name for it; an empty name takes the
    ///   suggested name.
    func savePreset(named name: String) {
        guard let camera = selectedCamera else { return }
        model?.savePreset(named: name, camera: camera, values: cameraParameterValues)
    }

    /// Recalls a preset in this window: selects its camera, if another is
    /// showing, and writes the preset's values to it. Nothing happens while
    /// its camera is not connected.
    ///
    /// - Parameter id: The preset's identity.
    func recallPreset(_ id: CameraPreset.ID) {
        guard let model, let preset = model.presets.preset(withID: id), let camera = model.camera(for: preset)
        else { return }
        model.reportPreset("cameraPreset.applied", preset, extra: ["reason": .string("recall")])
        guard camera.id != selectedCameraID else {
            // The camera is already showing: write the values without
            // reopening it, so the preview does not blink.
            // The whole payload, since an omitted key means its default.
            cameraParameterValues.merge(preset.values) { _, preset in preset }
            let values = cameraParameterValues
            Task { await feed?.applyCameraParameters(values, toCamera: camera.id) }
            return
        }
        selectedCameraID = camera.id
        model.rememberSelectedCamera(camera)
        Task { await feed?.showCamera(id: camera.id, applying: preset.values) }
    }

    /// Replaces a preset's values with the window's camera's current
    /// settings — only for that camera's own preset.
    ///
    /// - Parameter id: The preset's identity.
    func updatePreset(_ id: CameraPreset.ID) {
        guard let preset = model?.presets.preset(withID: id), canUpdatePreset(preset) else { return }
        model?.updatePreset(id, values: cameraParameterValues)
    }

    /// A session over the static preview model, selecting its first camera,
    /// for Xcode previews.
    ///
    /// - Parameter model: The preview model.
    /// - Returns: The session.
    static func preview(_ model: HardwareModel) -> CameraSession {
        let session = CameraSession()
        session.model = model
        session.selectedCameraID = model.cameras.first?.id
        return session
    }
}

extension FocusedValues {
    /// The key window's camera session — how the menu bar's Copy and Presets
    /// commands act on the camera of the window the operator is working in.
    @Entry var cameraSession: CameraSession?
}

extension View {
    /// Injects the static preview model and a session over it, the
    /// environment every window's views read, for Xcode previews.
    ///
    /// - Returns: The view with both in its environment.
    func previewEnvironment() -> some View {
        let model = HardwareModel.preview
        return environment(model).environment(CameraSession.preview(model))
    }
}
