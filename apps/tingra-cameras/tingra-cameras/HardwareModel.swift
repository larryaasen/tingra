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

/// The app-wide observable state: the available cameras, the operator's
/// camera presets, the camera permission, and the preview's cross bars —
/// shared by every window.
///
/// Which camera a window shows, and that camera's controls, belong to the
/// window's own ``CameraSession``, so each window can show a different
/// camera; this model tells the sessions when the cameras or the permission
/// change, and chooses the camera a new window opens on.
@MainActor
@Observable
final class HardwareModel {
    /// The cameras offered in the CAMERAS section, in display order.
    private(set) var cameras: [Device]

    /// Whether the preview shows its cross bars — lines through its centre.
    /// Remembered across launches, like a view option in any Mac app.
    var showsCrossBars = UserDefaults.standard.bool(forKey: HardwareModel.showsCrossBarsKey) {
        didSet { UserDefaults.standard.set(showsCrossBars, forKey: Self.showsCrossBarsKey) }
    }

    /// The defaults key remembering ``showsCrossBars``.
    private static let showsCrossBarsKey = "showsCrossBars"

    /// Where the camera permission stands — the Permissions settings pane's
    /// model, refreshed whenever the app becomes active.
    let permissions: PermissionsModel

    /// The discovery in flight or done, so a second window's start waits for
    /// the first rather than activating the capture plug-in again.
    private var startTask: Task<Void, Never>?

    /// The engine bridge that discovers hardware and runs the windows'
    /// cameras, or `nil` for the static preview model used in Xcode previews
    /// (which lists placeholder devices but opens no camera).
    private let engine: CaptureEngine?

    /// The windows' camera sessions, told when the cameras or the camera
    /// permission change. Weak, so a closed window's session goes with it.
    @ObservationIgnored private let sessions = NSHashTable<CameraSession>.weakObjects()

    /// Whether a window has opened since launch, so only the first applies
    /// the default preset — the launch rule, not a new window's.
    @ObservationIgnored private var hasOpenedFirstWindow = false

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
    ///   - cameras: The cameras to list.
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
    }

    /// Discovers the connected cameras through the engine. A no-op for the
    /// static preview model, which has no engine.
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

    /// The body of ``start()``: discovers the cameras and begins following
    /// the camera permission. Each window then chooses its camera
    /// (``cameraForNewWindow(restoringID:name:)``).
    ///
    /// - Parameter engine: The engine to discover through.
    private func discover(with engine: CaptureEngine) async {
        applyDevices(cameras: await engine.discover())
        permissions.refresh()
        permissions.observeActivation { [weak self] granted in
            self?.applyNewlyGranted(granted)
        }
    }

    /// Restarts every window's preview that was showing why its camera
    /// could not open, when the camera permission has just been granted — so
    /// a grant made in System Settings or from the Permissions pane shows the
    /// cameras without the operator selecting them again.
    ///
    /// - Parameter granted: The permissions that newly became granted.
    func applyNewlyGranted(_ granted: Set<AuthorizationPermission>) {
        guard granted.contains(.camera) else { return }
        for session in sessions.allObjects {
            session.retryAfterPermissionGrant()
        }
    }

    /// Makes the feed a window shows its camera through, or nil for the
    /// static preview model, which opens no camera.
    ///
    /// - Returns: A new feed, or nil.
    func makeFeed() -> CameraFeed? {
        engine?.makeFeed()
    }

    /// Starts telling a window's session when the cameras or the camera
    /// permission change.
    ///
    /// - Parameter session: The session.
    func register(_ session: CameraSession) {
        sessions.add(session)
    }

    /// Stops telling a closed window's session about changes.
    ///
    /// - Parameter session: The session.
    func unregister(_ session: CameraSession) {
        sessions.remove(session)
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

    /// Records a tap on one of a camera's controls, in the `capture` domain
    /// with its own parameters — a control's key and value, or a framing.
    ///
    /// - Parameters:
    ///   - name: The dotted tap name, e.g. `cameraParameter.slider`.
    ///   - params: The tap's parameters, or nil for none.
    func recordCaptureTap(_ name: String, params: [String: EventValue]?) {
        engine?.recordTap(name, params: params)
    }

    /// Records a tap concerning one camera, in the `capture` domain with the
    /// camera's identifier.
    ///
    /// - Parameters:
    ///   - name: The dotted tap name, e.g. `cameraSelect.row`.
    ///   - deviceID: The camera, or nil for none.
    func recordCaptureTap(_ name: String, deviceID: Device.ID?) {
        engine?.recordTap(name, deviceID: deviceID)
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

    /// Stops every window's camera and the engine, e.g. as the app quits.
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

    /// The name the Save Preset dialog offers: the next numbered preset name
    /// not already taken.
    var suggestedPresetName: String {
        presets.suggestedName { number in
            String(
                localized: "Preset \(number)", comment: "Suggested name of a new camera preset; the number counts up")
        }
    }

    /// Saves a camera's settings as a new preset — the first one saved
    /// becomes the default — and writes the presets to disk. A window saves
    /// its own camera's (``CameraSession/savePreset(named:)``).
    ///
    /// - Parameters:
    ///   - name: The operator's name for it; an empty name takes
    ///     ``suggestedPresetName``.
    ///   - camera: The camera the settings are for.
    ///   - values: Its control values.
    func savePreset(named name: String, camera: Device, values: [String: JSONValue]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let preset = presets.save(
                name: trimmed.isEmpty ? suggestedPresetName : trimmed,
                cameraID: camera.id,
                cameraName: camera.name,
                values: values
            )
        else { return }
        reportPreset("cameraPreset.saved", preset, extra: ["default": .bool(presets.isDefault(preset.id))])
        writePresets()
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

    /// Replaces a preset's values and writes the presets to disk. A window
    /// updates a preset with its own camera's settings, and only that
    /// camera's preset (``CameraSession/updatePreset(_:)``).
    ///
    /// - Parameters:
    ///   - id: The preset's identity.
    ///   - values: The camera's current control values.
    func updatePreset(_ id: CameraPreset.ID, values: [String: JSONValue]) {
        guard let preset = presets.preset(withID: id), presets.update(id, values: values) else { return }
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

    /// The camera a window opens on, once the cameras are discovered, and
    /// the preset values to write to it.
    ///
    /// A window macOS restores reopens on the camera it showed, when that is
    /// connected. Otherwise a window opens on the camera the operator last
    /// chose, else the default preset's camera, else the first camera. The
    /// first window since launch also applies the launch rule: the default
    /// preset's values are written to its camera when the camera opening is
    /// the preset's own, so a launch back onto another camera shows it as it
    /// is.
    ///
    /// - Parameters:
    ///   - restoringID: The camera the window showed when last open, or nil.
    ///   - name: That camera's name, matched when its identifier changed.
    /// - Returns: The camera and any preset values, or nil with no camera
    ///   connected.
    func cameraForNewWindow(
        restoringID: Device.ID?,
        name: String?
    ) -> (camera: Device, values: [String: JSONValue]?)? {
        let isFirstWindow = !hasOpenedFirstWindow
        hasOpenedFirstWindow = true
        let preset = presets.defaultPreset
        let presetCamera = preset?.camera(among: cameras, id: \.id, name: \.name)
        if isFirstWindow, let preset, presetCamera == nil {
            // Its camera being away is normal — it is unplugged — so this is
            // an event, not an error.
            reportPreset("cameraPreset.cameraAbsent", preset)
        }
        let restored = cameras.first { $0.id == restoringID } ?? cameras.first { $0.name == name }
        guard let camera = restored ?? rememberedCamera(among: cameras) ?? presetCamera ?? cameras.first else {
            return nil
        }
        guard isFirstWindow, let preset, presetCamera?.id == camera.id else { return (camera, nil) }
        reportPreset("cameraPreset.applied", preset, extra: ["reason": .string("launch")])
        return (camera, preset.values)
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

    /// Remembers the operator's camera choice, in any window, so the next
    /// window and the next launch open it. Only the operator's choices are
    /// remembered: the fallback to the first camera when the chosen one
    /// disconnects is not, so the chosen camera returns at the next launch it
    /// is connected for.
    ///
    /// - Parameter camera: The camera the operator chose.
    func rememberSelectedCamera(_ camera: Device) {
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
    func reportPreset(_ name: String, _ preset: CameraPreset, extra: [String: EventValue] = [:]) {
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

    /// Adopts a freshly discovered device set and tells every window, so
    /// each keeps its selection valid: a window whose camera has
    /// disconnected falls back to the first available camera
    /// (``CameraSession/followDevices(_:)``).
    ///
    /// - Parameter cameras: The current cameras, in display order.
    private func applyDevices(cameras: [Device]) {
        self.cameras = cameras
        for session in sessions.allObjects {
            session.followDevices(cameras)
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
