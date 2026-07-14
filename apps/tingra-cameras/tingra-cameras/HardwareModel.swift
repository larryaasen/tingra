//
//  HardwareModel.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// The kind of hardware a ``Device`` represents, which drives how its row
/// icon is rendered in the sidebar (a square bounding box for cameras, a
/// pill/oval for microphones).
enum DeviceKind: Hashable, Sendable {
    /// A video capture input (e.g. a built-in or external camera).
    case camera
    /// An audio capture input (e.g. a built-in or USB microphone).
    case microphone
}

/// A single selectable hardware input shown in the sidebar.
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
    /// Whether this device is a camera or a microphone.
    let kind: DeviceKind
}

/// The observable state backing the hardware picker: the available cameras
/// and microphones and the operator's current selection in each list.
///
/// The view layer owns one instance via `@State` and reads/writes selection
/// through `@Bindable`; the model is the single source of truth for which
/// camera feeds the preview canvas.
@MainActor
@Observable
final class HardwareModel {
    /// The cameras offered in the CAMERAS section, in display order.
    private(set) var cameras: [Device]

    /// The microphones offered in the MICROPHONES section, in display order.
    private(set) var microphones: [Device]

    /// The identifier of the currently selected camera, or `nil` if none is
    /// selected. Drives the sidebar highlight and the preview feed.
    private(set) var selectedCameraID: Device.ID?

    /// The identifier of the currently selected microphone, or `nil` if none
    /// is selected.
    private(set) var selectedMicrophoneID: Device.ID?

    /// A short, user-facing message describing why the live preview cannot be
    /// shown (authorization denied, device unavailable), or `nil` when the
    /// preview is healthy. Surfaced by the preview canvas.
    private(set) var previewError: String?

    /// The engine bridge that discovers hardware and drives the selected
    /// camera's feed, or `nil` for the static preview model used in Xcode
    /// previews (which lists placeholder devices but opens no camera).
    private let engine: CaptureEngine?

    /// Creates a model seeded with the given devices and an optional engine.
    ///
    /// - Parameters:
    ///   - cameras: The cameras to list; the first is selected by default.
    ///   - microphones: The microphones to list; none is selected by default.
    ///   - engine: The engine bridge that supplies live hardware and the
    ///     preview feed, or `nil` for a static (preview-only) model.
    init(cameras: [Device], microphones: [Device], engine: CaptureEngine? = nil) {
        self.cameras = cameras
        self.microphones = microphones
        self.selectedCameraID = cameras.first?.id
        self.selectedMicrophoneID = nil
        self.engine = engine
        engine?.onDevicesChanged = { [weak self] cameras, microphones in
            self?.applyDevices(cameras: cameras, microphones: microphones)
        }
        engine?.onPreviewError = { [weak self] message in
            self?.previewError = message
        }
    }

    /// The camera the preview canvas should display, resolved from
    /// ``selectedCameraID``, or `nil` when nothing is selected.
    var selectedCamera: Device? {
        guard let selectedCameraID else { return nil }
        return cameras.first { $0.id == selectedCameraID }
    }

    /// Discovers the connected cameras and microphones through the engine
    /// and begins showing the first camera. A no-op for the static preview
    /// model, which has no engine.
    func start() async {
        guard let engine else { return }
        let devices = await engine.discover()
        applyDevices(cameras: devices.cameras, microphones: devices.microphones)
        await engine.showCamera(id: selectedCameraID)
    }

    /// Selects a camera and switches the live preview to it.
    ///
    /// - Parameter id: The chosen camera's identifier.
    func selectCamera(_ id: Device.ID) {
        // Record the click first, distinct from its effect — even a tap on
        // the already-selected camera is a real click (see EVENTS.md).
        engine?.recordTap("cameraSelect.row", deviceID: id)
        guard id != selectedCameraID else { return }
        selectedCameraID = id
        Task { await engine?.showCamera(id: id) }
    }

    /// Selects a microphone. The app previews video only, so this updates the
    /// sidebar highlight without opening the microphone.
    ///
    /// - Parameter id: The chosen microphone's identifier.
    func selectMicrophone(_ id: Device.ID) {
        engine?.recordTap("microphoneSelect.row", deviceID: id)
        selectedMicrophoneID = id
    }

    /// Connects the preview canvas's display sink to the engine, so live
    /// frames flow straight to the screen.
    ///
    /// - Parameters:
    ///   - renderFrame: Draws one captured frame in the preview.
    ///   - flush: Clears any displayed frame, used when switching cameras.
    func attachPreview(
        renderFrame: @escaping @MainActor (CapturedFrame) -> Void,
        flush: @escaping @MainActor () -> Void
    ) {
        engine?.renderFrame = renderFrame
        engine?.flushPreview = flush
    }

    /// Disconnects the preview sink when the preview canvas goes away, so no
    /// frames are drawn into a torn-down view.
    func detachPreview() {
        engine?.renderFrame = nil
        engine?.flushPreview = nil
    }

    /// Stops the preview and releases the camera, e.g. when the window
    /// closes.
    func stop() async {
        await engine?.stop()
    }

    /// Adopts a freshly discovered device set, keeping the selection valid:
    /// if the selected camera has disconnected, it falls back to the first
    /// available camera (and switches the preview to it).
    ///
    /// - Parameters:
    ///   - cameras: The current cameras, in display order.
    ///   - microphones: The current microphones, in display order.
    private func applyDevices(cameras: [Device], microphones: [Device]) {
        self.cameras = cameras
        self.microphones = microphones

        if selectedCameraID == nil || !cameras.contains(where: { $0.id == selectedCameraID }) {
            let replacement = cameras.first?.id
            selectedCameraID = replacement
            Task { await engine?.showCamera(id: replacement) }
        }
        if let selectedMicrophoneID, !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            self.selectedMicrophoneID = nil
        }
    }

    /// A model populated with placeholder devices matching the design
    /// wireframe, with no engine. Used by Xcode previews so the layout
    /// renders without touching real hardware.
    static var preview: HardwareModel {
        HardwareModel(
            cameras: [
                Device(id: "facetime-hd", name: "FaceTime HD Camera", kind: .camera),
                Device(id: "logitech-brio", name: "Logitech Brio", kind: .camera),
                Device(id: "iphone-continuity", name: "iPhone Continuity Cam", kind: .camera),
            ],
            microphones: [
                Device(id: "macbook-mic", name: "MacBook Microphone", kind: .microphone),
                Device(id: "shure-mv7", name: "Shure MV7", kind: .microphone),
                Device(id: "airpods-pro", name: "AirPods Pro", kind: .microphone),
            ]
        )
    }

    /// A live, engine-backed model with empty lists until ``start()`` runs
    /// discovery. This is the model the app injects at launch.
    static var live: HardwareModel {
        HardwareModel(cameras: [], microphones: [], engine: CaptureEngine())
    }
}
