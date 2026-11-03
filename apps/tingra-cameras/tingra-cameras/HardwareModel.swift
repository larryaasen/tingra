//
//  HardwareModel.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// A single selectable camera shown in the sidebar.
///
/// This is a lightweight, view-facing value type. When a real
/// `AVCaptureDevice` layer is wired in behind ``CameraPreviewView``, its
/// `uniqueID` maps onto ``Device/id`` so selection resolves to a concrete
/// device without changing the view layer.
struct Device: Identifiable, Hashable, Sendable {
    /// A stable identity for the device, used for selection and, later, to
    /// resolve the underlying `AVCaptureDevice.uniqueID`.
    let id: String
    /// The human-readable device name shown in the sidebar row.
    let name: String
}

/// Where the selected camera's preview stands — the status bar's leading
/// reading.
enum PreviewState: Equatable, Sendable {
    /// No camera is selected (none is connected).
    case noCamera
    /// The selected camera is opening and has delivered no frame yet.
    case starting
    /// The selected camera's frames are showing.
    case live
    /// The selected camera could not be opened; the preview says why.
    case unavailable
}

/// The observable state backing the camera picker: the available cameras,
/// the operator's selection, and the selected camera's controls.
///
/// The view layer owns one instance via `@State` and reads/writes selection
/// through `@Bindable`; the model is the single source of truth for which
/// camera feeds the preview canvas.
@MainActor
@Observable
final class HardwareModel {
    /// The cameras offered in the CAMERAS section, in display order.
    private(set) var cameras: [Device]

    /// The identifier of the currently selected camera, or `nil` if none is
    /// selected. Drives the sidebar highlight and the preview feed.
    private(set) var selectedCameraID: Device.ID?

    /// A short, user-facing message describing why the live preview cannot be
    /// shown (authorization denied, device unavailable), or `nil` when the
    /// preview is healthy. Surfaced by the preview canvas.
    private(set) var previewError: String?

    /// The selected camera's adjustable controls, in display order — empty
    /// when no camera is selected or it has none (a built-in or Continuity
    /// camera). Drawn by the controls in the trailing sidebar.
    private(set) var cameraParameters: [Parameter] = []

    /// Whether the preview shows its cross bars — lines through its centre.
    /// Remembered across launches, like a view option in any Mac app.
    var showsCrossBars = UserDefaults.standard.bool(forKey: HardwareModel.showsCrossBarsKey) {
        didSet { UserDefaults.standard.set(showsCrossBars, forKey: Self.showsCrossBarsKey) }
    }

    /// The defaults key remembering ``showsCrossBars``.
    private static let showsCrossBarsKey = "showsCrossBars"

    /// The size of the frames the selected camera is delivering, or nil
    /// before its first frame — the status bar's resolution reading.
    private(set) var frameDimensions: PixelDimensions?

    /// Where the camera permission stands — the Permissions settings pane's
    /// model, refreshed whenever the app becomes active.
    let permissions: PermissionsModel

    /// The discovery in flight or done, so a second window's start waits for
    /// the first rather than activating the capture plug-in again.
    private var startTask: Task<Void, Never>?

    /// The selected camera's control values, keyed by parameter — the
    /// camera's own values when it was selected, then the operator's edits.
    private(set) var cameraParameterValues: [String: JSONValue] = [:]

    /// The engine bridge that discovers hardware and drives the selected
    /// camera's feed, or `nil` for the static preview model used in Xcode
    /// previews (which lists placeholder devices but opens no camera).
    private let engine: CaptureEngine?

    /// The operator's camera presets and which is the default applied at
    /// launch — read from ``presetStore`` as the model is made, and written
    /// back on every change.
    private(set) var presets: CameraPresets

    /// Where the presets persist (`camera-presets.json` in Tingra's
    /// Application Support folder), or `nil` for the static preview model,
    /// which keeps its presets in memory.
    private let presetStore: CameraPresetStore?

    /// Where the operator's camera choice is remembered across launches, or
    /// `nil` for the static preview model, which remembers nothing.
    private let selectionDefaults: UserDefaults?

    /// The defaults key remembering the identifier of the camera the
    /// operator last chose.
    private static let selectedCameraIDKey = "selectedCameraID"

    /// The defaults key remembering the name of the camera the operator last
    /// chose — the fallback when its identifier changes because it was
    /// plugged into another port.
    private static let selectedCameraNameKey = "selectedCameraName"

    /// Creates a model seeded with the given devices and an optional engine.
    ///
    /// - Parameters:
    ///   - cameras: The cameras to list; the first is selected by default.
    ///   - engine: The engine bridge that supplies live hardware and the
    ///     preview feed, or `nil` for a static (preview-only) model.
    ///   - presetStore: Where the camera presets persist, or `nil` to keep
    ///     them in memory.
    ///   - presets: The presets to start with when there is no store.
    ///   - selectionDefaults: Where the operator's camera choice is
    ///     remembered across launches, or `nil` to remember nothing.
    init(
        cameras: [Device],
        engine: CaptureEngine? = nil,
        presetStore: CameraPresetStore? = nil,
        presets: CameraPresets = CameraPresets(),
        selectionDefaults: UserDefaults? = nil
    ) {
        self.cameras = cameras
        self.selectedCameraID = cameras.first?.id
        self.engine = engine
        self.presetStore = presetStore
        self.selectionDefaults = selectionDefaults
        self.presets = presetStore.map { Self.readPresets(from: $0, eventBus: engine?.eventBus) } ?? presets
        // The engine's bus when there is one, so the permission events land
        // beside the capture events; the static preview model has its own.
        self.permissions = PermissionsModel(
            permissions: [.camera],
            authorization: SystemAuthorization(),
            eventBus: engine?.eventBus ?? EventBus()
        )
        engine?.onDevicesChanged = { [weak self] cameras in
            self?.applyDevices(cameras: cameras)
        }
        engine?.onPreviewError = { [weak self] message in
            self?.previewError = message
        }
        engine?.onCameraParametersChanged = { [weak self] parameters, values in
            self?.cameraParameters = parameters
            self?.cameraParameterValues = values
        }
        engine?.onFrameDimensionsChanged = { [weak self] dimensions in
            self?.frameDimensions = dimensions
        }
    }

    /// The camera the preview canvas should display, resolved from
    /// ``selectedCameraID``, or `nil` when nothing is selected.
    var selectedCamera: Device? {
        guard let selectedCameraID else { return nil }
        return cameras.first { $0.id == selectedCameraID }
    }

    /// Where the selected camera's preview stands, for the status bar.
    var previewState: PreviewState {
        if selectedCamera == nil { return .noCamera }
        if previewError != nil { return .unavailable }
        return frameDimensions == nil ? .starting : .live
    }

    /// Discovers the connected cameras through the engine
    /// and begins showing the first camera. A no-op for the static preview
    /// model, which has no engine.
    ///
    /// Every window runs this as it appears, and every window shares this
    /// model, so only the first call discovers: a later one waits for that
    /// discovery and returns. Discovering again would activate the capture
    /// plug-in a second time.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        guard let engine else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await discover(with: engine)
        }
        startTask = task
        await task.value
    }

    /// The body of ``start()``: discovers the cameras, shows the one the
    /// launch selects (``applyLaunchSelection(among:)``), and begins
    /// following the camera permission.
    ///
    /// - Parameter engine: The engine to discover through.
    private func discover(with engine: CaptureEngine) async {
        let cameras = await engine.discover()
        if !applyLaunchSelection(among: cameras) {
            // Adopting the devices selects the first camera and starts it:
            // the live model begins with no selection, so `applyDevices`
            // always switches here. Starting it again would cancel that
            // start and open the same camera twice.
            applyDevices(cameras: cameras)
        }
        permissions.refresh()
        permissions.observeActivation { [weak self] granted in
            self?.applyNewlyGranted(granted)
        }
    }

    /// Restarts the selected camera's preview when the camera permission has
    /// just been granted and the preview was showing why it could not open —
    /// so a grant made in System Settings or from the Permissions pane shows
    /// the camera without the operator selecting it again.
    ///
    /// - Parameter granted: The permissions that newly became granted.
    func applyNewlyGranted(_ granted: Set<AuthorizationPermission>) {
        guard granted.contains(.camera), previewError != nil, let selectedCameraID else { return }
        Task { await engine?.showCamera(id: selectedCameraID) }
    }

    /// Records a tap on one of the app's own controls — a setting, a menu
    /// command — distinct from the change it makes (EVENTS.md, "The `tap`
    /// convention").
    ///
    /// - Parameters:
    ///   - name: The dotted tap name, e.g. `statusBar.menuItem`.
    ///   - params: The tap's parameters, or nil for none.
    func recordTap(_ name: String, params: [String: EventValue]? = nil) {
        engine?.recordTap(name, domain: .platform, params: params)
    }

    /// Selects a camera and switches the live preview to it. Selecting the
    /// camera already selected restarts it when its preview could not open,
    /// so reselecting it — what the preview's error tells the operator to
    /// do — tries again.
    ///
    /// - Parameter id: The chosen camera's identifier.
    func selectCamera(_ id: Device.ID) {
        // Record the click first, distinct from its effect — even a tap on
        // the already-selected camera is a real click (see EVENTS.md).
        engine?.recordTap("cameraSelect.row", deviceID: id)
        guard id != selectedCameraID || previewError != nil else { return }
        selectedCameraID = id
        if let camera = cameras.first(where: { $0.id == id }) {
            rememberSelectedCamera(camera)
        }
        Task { await engine?.showCamera(id: id) }
    }

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
        engine?.setCameraParameters(cameraParameterValues, refreshing: parameter.kind != .number)
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
        engine?.recordTap("cameraParameter.reset", params: params)
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
        engine?.recordTap(name, params: params)
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
        engine?.setCameraParameters([:], refreshing: true)
    }

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

    /// The unsnapped values a framing gesture has moved to so far, by key.
    /// A drag or pinch moves in small increments; snapping each one to the
    /// camera's step on its own would round it away, so the gesture
    /// accumulates here and only what it sends is snapped. Cleared when the
    /// gesture ends.
    private var framingGestureValues: [String: Double] = [:]

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
        engine?.recordTap(name, params: params)
    }

    /// Whether Copy has a live camera frame to copy: a camera is selected
    /// and showing.
    var canCopyFrame: Bool {
        selectedCamera != nil && previewError == nil
    }

    /// Copies the selected camera's current frame to the pasteboard,
    /// recording the tap first (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameter source: Where Copy was chosen: `menu` (the Edit menu or
    ///   ⌘C) or `contextMenu` (the preview's context menu).
    func copyFrame(from source: String) {
        engine?.recordTap("previewCopy.\(source)", deviceID: selectedCameraID)
        engine?.copyCurrentFrame()
    }

    /// Shows or hides the preview's cross bars, recording the tap first with
    /// the state it leaves.
    ///
    /// - Parameter source: Where Cross Bars was chosen: `menu` (the View
    ///   menu) or `contextMenu` (the preview's context menu).
    func toggleCrossBars(from source: String) {
        let showsCrossBars = !self.showsCrossBars
        engine?.recordTap("crossBars.\(source)", params: ["value": .bool(showsCrossBars)])
        self.showsCrossBars = showsCrossBars
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
        engine?.recordTap(name, params: params)
    }

    /// Connects one preview's display sink to the engine, so live frames
    /// flow straight to the screen. Each window's preview connects its own,
    /// and every one draws the selected camera.
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
        engine?.addPreviewSink(id: id, render: renderFrame, flush: flush)
    }

    /// Disconnects one preview's sink when its view goes away, so no frames
    /// are drawn into a torn-down view — and every other window's preview
    /// keeps drawing.
    ///
    /// - Parameter id: The identity the preview attached under.
    func detachPreview(id: ObjectIdentifier) {
        engine?.removePreviewSink(id: id)
    }

    /// Stops the preview and releases the camera, e.g. when the window
    /// closes.
    func stop() async {
        await engine?.stop()
    }

    // MARK: Camera presets

    /// The connected camera a preset is for — the one with its camera's id,
    /// else the one with its camera's name — or nil while that camera is not
    /// connected.
    ///
    /// - Parameter preset: The preset.
    /// - Returns: Its camera, or nil.
    func camera(for preset: CameraPreset) -> Device? {
        preset.camera(among: cameras, id: \.id, name: \.name)
    }

    /// Whether there is a camera whose settings a new preset can save: one is
    /// selected.
    var canSavePreset: Bool {
        selectedCamera != nil
    }

    /// Whether a preset can be updated with the selected camera's current
    /// settings: it is that camera's preset.
    ///
    /// - Parameter preset: The preset.
    /// - Returns: Whether Update Preset applies.
    func canUpdatePreset(_ preset: CameraPreset) -> Bool {
        guard let selectedCameraID else { return false }
        return camera(for: preset)?.id == selectedCameraID
    }

    /// The name the Save Preset dialog offers: the next numbered preset name
    /// not already taken.
    var suggestedPresetName: String {
        presets.suggestedName { number in
            String(
                localized: "Preset \(number)", comment: "Suggested name of a new camera preset; the number counts up")
        }
    }

    /// Saves the selected camera's settings as a new preset — the first one
    /// saved becomes the default — and writes the presets to disk.
    ///
    /// - Parameter name: The operator's name for it; an empty name takes
    ///   ``suggestedPresetName``.
    func savePreset(named name: String) {
        guard let camera = selectedCamera else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let preset = presets.save(
                name: trimmed.isEmpty ? suggestedPresetName : trimmed,
                cameraID: camera.id,
                cameraName: camera.name,
                values: cameraParameterValues
            )
        else { return }
        reportPreset("cameraPreset.saved", preset, extra: ["default": .bool(presets.isDefault(preset.id))])
        writePresets()
    }

    /// Recalls a preset: selects its camera, if another is showing, and
    /// writes the preset's values to it. Nothing happens while its camera is
    /// not connected.
    ///
    /// - Parameter id: The preset's identity.
    func recallPreset(_ id: CameraPreset.ID) {
        guard let preset = presets.preset(withID: id), let camera = camera(for: preset) else { return }
        reportPreset("cameraPreset.applied", preset, extra: ["reason": .string("recall")])
        guard camera.id != selectedCameraID else {
            // The camera is already showing: write the values without
            // reopening it, so the preview does not blink.
            // The whole payload, since an omitted key means its default.
            cameraParameterValues.merge(preset.values) { _, preset in preset }
            let values = cameraParameterValues
            Task { await engine?.applyCameraParameters(values, toCamera: camera.id) }
            return
        }
        selectedCameraID = camera.id
        rememberSelectedCamera(camera)
        Task { await engine?.showCamera(id: camera.id, applying: preset.values) }
    }

    /// Makes a preset the one applied at launch, and writes the presets to
    /// disk.
    ///
    /// - Parameter id: The preset's identity.
    func makeDefaultPreset(_ id: CameraPreset.ID) {
        guard presets.makeDefault(id), let preset = presets.preset(withID: id) else { return }
        reportPreset("cameraPreset.defaultChanged", preset)
        writePresets()
    }

    /// Renames a preset and writes the presets to disk. An empty name
    /// changes nothing.
    ///
    /// - Parameters:
    ///   - id: The preset's identity.
    ///   - name: The new name.
    func renamePreset(_ id: CameraPreset.ID, to name: String) {
        guard presets.rename(id, to: name), let preset = presets.preset(withID: id) else { return }
        reportPreset("cameraPreset.renamed", preset)
        writePresets()
    }

    /// Replaces a preset's values with the selected camera's current
    /// settings — only for that camera's own preset — and writes the presets
    /// to disk.
    ///
    /// - Parameter id: The preset's identity.
    func updatePreset(_ id: CameraPreset.ID) {
        guard let preset = presets.preset(withID: id), canUpdatePreset(preset),
            presets.update(id, values: cameraParameterValues)
        else { return }
        reportPreset("cameraPreset.updated", preset)
        writePresets()
    }

    /// Deletes a preset — deleting the default hands the role to the first
    /// preset left — and writes the presets to disk.
    ///
    /// - Parameter id: The preset's identity.
    func deletePreset(_ id: CameraPreset.ID) {
        guard let preset = presets.delete(id) else { return }
        var extra: [String: EventValue] = [:]
        if let defaultPreset = presets.defaultPreset {
            extra["defaultPreset"] = .string(defaultPreset.id.uuidString)
        }
        reportPreset("cameraPreset.deleted", preset, extra: extra)
        writePresets()
    }

    /// Selects and starts the camera a launch opens once the cameras are
    /// discovered: the camera the operator last chose, else the default
    /// preset's camera. The default preset's values are written to that
    /// camera when it is the preset's own, so a launch back onto another
    /// camera shows it as it is.
    ///
    /// - Parameter cameras: The cameras discovered at launch.
    /// - Returns: Whether a camera was selected; false when neither the
    ///   remembered camera nor the default preset's is connected, and the
    ///   launch shows the first camera instead.
    private func applyLaunchSelection(among cameras: [Device]) -> Bool {
        let preset = presets.defaultPreset
        let presetCamera = preset?.camera(among: cameras, id: \.id, name: \.name)
        if let preset, presetCamera == nil {
            // Its camera being away is normal — it is unplugged — so this is
            // an event, not an error.
            reportPreset("cameraPreset.cameraAbsent", preset)
        }
        guard let camera = rememberedCamera(among: cameras) ?? presetCamera else { return false }
        self.cameras = cameras
        selectedCameraID = camera.id
        guard let preset, presetCamera?.id == camera.id else {
            Task { await engine?.showCamera(id: camera.id) }
            return true
        }
        reportPreset("cameraPreset.applied", preset, extra: ["reason": .string("launch")])
        Task { await engine?.showCamera(id: camera.id, applying: preset.values) }
        return true
    }

    /// The connected camera the operator last chose: the one with the
    /// remembered identifier, else the first with the remembered name — the
    /// same camera plugged into another port — else nil, when it is not
    /// connected or nothing is remembered.
    ///
    /// - Parameter cameras: The connected cameras.
    /// - Returns: The remembered camera, or nil.
    private func rememberedCamera(among cameras: [Device]) -> Device? {
        guard let selectionDefaults else { return nil }
        let id = selectionDefaults.string(forKey: Self.selectedCameraIDKey)
        let name = selectionDefaults.string(forKey: Self.selectedCameraNameKey)
        return cameras.first { $0.id == id } ?? cameras.first { $0.name == name }
    }

    /// Remembers the operator's camera choice, so the next launch opens it.
    /// Only the operator's choices are remembered: the fallback to the first
    /// camera when the chosen one disconnects is not, so the chosen camera
    /// returns at the next launch it is connected for.
    ///
    /// - Parameter camera: The camera the operator chose.
    private func rememberSelectedCamera(_ camera: Device) {
        selectionDefaults?.set(camera.id, forKey: Self.selectedCameraIDKey)
        selectionDefaults?.set(camera.name, forKey: Self.selectedCameraNameKey)
    }

    /// Writes the presets to disk, reporting a `cameraPreset.write` error
    /// event when the file cannot be written; the presets stay in memory
    /// either way.
    private func writePresets() {
        guard let presetStore else { return }
        do {
            try presetStore.write(presets)
        } catch {
            engine?.eventBus.error(
                "cameraPreset.write",
                domain: .capture,
                params: [
                    "path": .string(presetStore.fileURL.path(percentEncoded: false)),
                    "error": .string(error.localizedDescription),
                ]
            )
        }
    }

    /// Reads the presets as the model is made. A file that cannot be read as
    /// presets is moved aside to its `.unreadable` sibling, reported as a
    /// `cameraPreset.read` error event, and the app starts with none — so
    /// the next preset saved begins a fresh file without destroying the old
    /// one.
    ///
    /// - Parameters:
    ///   - store: Where the presets persist.
    ///   - eventBus: The bus to report a read error on, or nil.
    /// - Returns: The presets, or none when the file cannot be read.
    private static func readPresets(from store: CameraPresetStore, eventBus: EventBus?) -> CameraPresets {
        do {
            return try store.read()
        } catch {
            var params: [String: EventValue] = [
                "path": .string(store.fileURL.path(percentEncoded: false)),
                "error": .string(error.localizedDescription),
            ]
            do {
                try store.setAsideUnreadableFile()
                params["movedTo"] = .string(store.unreadableFileURL.path(percentEncoded: false))
            } catch {
                params["moveError"] = .string(error.localizedDescription)
            }
            eventBus?.error("cameraPreset.read", domain: .capture, params: params)
            return CameraPresets()
        }
    }

    /// Reports a preset event on the bus with the preset's identity, name,
    /// and camera.
    ///
    /// - Parameters:
    ///   - name: The event name, e.g. `cameraPreset.saved`.
    ///   - preset: The preset it concerns.
    ///   - extra: Further parameters.
    private func reportPreset(_ name: String, _ preset: CameraPreset, extra: [String: EventValue] = [:]) {
        var params: [String: EventValue] = [
            "preset": .string(preset.id.uuidString),
            "name": .string(preset.name),
            "camera": .string(preset.cameraName),
        ]
        params.merge(extra) { _, extra in extra }
        engine?.eventBus.event(name, domain: .capture, params: params)
    }

    /// Records a tap on one of the preset controls, with the preset it
    /// concerns (EVENTS.md, "The `tap` convention").
    ///
    /// - Parameters:
    ///   - name: The dotted tap name, e.g. `cameraPreset.row`.
    ///   - preset: The preset, or nil for a control that concerns none.
    func recordPresetTap(_ name: String, preset: CameraPreset? = nil) {
        var params: [String: EventValue]?
        if let preset {
            params = ["preset": .string(preset.id.uuidString), "name": .string(preset.name)]
        }
        engine?.recordTap(name, params: params)
    }

    /// Adopts a freshly discovered device set, keeping the selection valid:
    /// if the selected camera has disconnected, it falls back to the first
    /// available camera (and switches the preview to it).
    ///
    /// - Parameters:
    /// - Parameter cameras: The current cameras, in display order.
    private func applyDevices(cameras: [Device]) {
        self.cameras = cameras

        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            let replacement = cameras.first?.id
            selectedCameraID = replacement
            Task { await engine?.showCamera(id: replacement) }
        }
    }

    /// A model populated with placeholder devices matching the design
    /// wireframe, with no engine. Used by Xcode previews so the layout
    /// renders without touching real hardware.
    static var preview: HardwareModel {
        var presets = CameraPresets()
        presets.save(name: "Desk", cameraID: "logitech-brio", cameraName: "Logitech Brio", values: [:])
        presets.save(name: "Wide", cameraID: "razer-kiyo", cameraName: "Razer Kiyo Pro", values: [:])
        return HardwareModel(
            cameras: [
                Device(id: "facetime-hd", name: "FaceTime HD Camera"),
                Device(id: "logitech-brio", name: "Logitech Brio"),
                Device(id: "iphone-continuity", name: "iPhone Continuity Cam"),
            ],
            presets: presets
        )
    }

    /// A live, engine-backed model with empty lists until ``start()`` runs
    /// discovery, the operator's saved camera presets, and the camera they
    /// last chose. This is the model the app injects at launch.
    static var live: HardwareModel {
        HardwareModel(
            cameras: [],
            engine: CaptureEngine(),
            presetStore: CameraPresetStore(),
            selectionDefaults: .standard
        )
    }
}
