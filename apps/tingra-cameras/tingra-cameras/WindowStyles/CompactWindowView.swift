//
//  CompactWindowView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The compact window (``WindowStyle/compact``), the default: everything
/// the standard window shows, in one narrow column, for the camera this
/// window shows (``CameraSession``).
///
/// From the top, the camera picker and the Presets pull-down
/// (``CompactPresetsMenu``) stand in for the standard window's sidebar, the
/// preview (``PreviewFrame``) keeps its 16:9 frame at the column's width,
/// and the selected camera's controls (``CameraControlsView``, the trailing
/// sidebar's form) fill the rest, scrolling under the preview rather than
/// moving it. The status bar runs across the bottom, as in the standard
/// window.
///
/// The column's width is bounded at both ends: past ``maximumWidth`` the
/// standard window is the better window, and ``minimumWidth`` is the
/// narrowest the controls' rows stay legible.
struct CompactWindowView: View {
    /// The narrowest the window may be.
    static let minimumWidth: CGFloat = 340

    /// The width a first opening starts at.
    static let idealWidth: CGFloat = 380

    /// The widest the window may be.
    static let maximumWidth: CGFloat = 520

    /// The shortest the window may be: the picker, the preview, and a few
    /// rows of controls at the narrowest width.
    static let minimumHeight: CGFloat = 480

    /// The height a first opening starts at, tall enough for a USB webcam's
    /// usual controls without scrolling.
    static let idealHeight: CGFloat = 820

    /// The window's camera session (``WindowSession``).
    @Environment(CameraSession.self) private var session

    /// The column.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CompactCameraPicker()
                CompactPresetsMenu()
            }
            .padding([.horizontal, .top])

            PreviewFrame()
                .padding()

            if session.selectedCamera != nil {
                Divider()

                CameraControlsView()
                    // The window's own background, so the form reads as part
                    // of the one column rather than a panel set into it.
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                Spacer(minLength: 0)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView()
        }
        // The product's name in the title bar: the picker right under it
        // already names the camera. The product name is the same in every
        // language.
        .navigationTitle(Text(verbatim: "Tingra Cameras"))
        .frame(
            minWidth: Self.minimumWidth,
            idealWidth: Self.idealWidth,
            maxWidth: Self.maximumWidth,
            minHeight: Self.minimumHeight,
            idealHeight: Self.idealHeight,
            maxHeight: .infinity
        )
    }
}

/// The compact window's camera picker: a pop-up button listing the connected
/// cameras, choosing one switching the preview to it — the standard window's
/// Cameras sidebar section, in one control.
private struct CompactCameraPicker: View {
    /// The shared model, for the connected cameras.
    @Environment(HardwareModel.self) private var model

    /// The window's camera session, whose camera the picker chooses.
    @Environment(CameraSession.self) private var session

    /// The picker, or a note when no camera is connected.
    var body: some View {
        if model.cameras.isEmpty {
            Text(
                "No cameras connected",
                comment: "Sidebar placeholder when no camera is discovered"
            )
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker(selection: selection) {
                ForEach(model.cameras) { camera in
                    // A camera's name is a proper noun from the system.
                    Label {
                        Text(verbatim: camera.name)
                    } icon: {
                        Image(systemName: "video")
                    }
                    .tag(Optional(camera.id))
                }
            } label: {
                Text(
                    "Camera",
                    comment:
                        "Permissions settings: the camera permission's name; also the compact window's camera picker label"
                )
            }
        }
    }

    /// The picker's selection: the selected camera. Choosing one selects it
    /// through the model, which reports the picker's own tap first.
    private var selection: Binding<Device.ID?> {
        Binding {
            session.selectedCameraID
        } set: { id in
            guard let id else { return }
            session.selectCamera(id, tapName: "cameraSelect.picker")
        }
    }
}

#Preview {
    CompactWindowView()
        .previewEnvironment()
        .environment(StatusBarModel())
        .frame(width: CompactWindowView.idealWidth, height: CompactWindowView.idealHeight)
}
