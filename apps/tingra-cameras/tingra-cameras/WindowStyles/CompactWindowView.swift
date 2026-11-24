//
//  CompactWindowView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

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
/// The controls sit under one Controls heading (``ControlsDisclosure``)
/// that collapses them, the compact window's Hide Inspector: collapsed, the
/// window shrinks to the picker and the preview and can't be made taller;
/// expanded again, it returns to the height it had before. Both are per
/// window, in `@SceneStorage`, like the standard window's trailing sidebar.
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

    /// The shared model, for the disclosure's `tap` record.
    @Environment(HardwareModel.self) private var model

    /// Whether the camera's controls are showing under the Controls heading.
    @SceneStorage("controls.isExpanded") private var isControlsExpanded = true

    /// The window's height when its controls were last collapsed, which
    /// expanding them restores; zero until they have been.
    @SceneStorage("controls.expandedHeight") private var expandedHeight: Double = 0

    /// The window, which SwiftUI can't return to an earlier height itself.
    @State private var hostWindow = HostWindow()

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

                ControlsDisclosure(isExpanded: controlsExpansion)

                if isControlsExpanded {
                    CameraControlsView()
                        // The window's own background, so the form reads as
                        // part of the one column rather than a panel set into
                        // it.
                        .scrollContentBackground(.hidden)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBarView()
        }
        // Collapsed, the column is exactly as tall as the picker, the preview
        // at the column's width, and the status bar, so the window (sized by
        // its content) shrinks to them and keeps that height.
        .fixedSize(horizontal: false, vertical: isCollapsed)
        // The product's name in the title bar: the picker right under it
        // already names the camera. The product name is the same in every
        // language.
        .navigationTitle(Text(verbatim: "Tingra Cameras"))
        .frame(
            minWidth: Self.minimumWidth,
            idealWidth: Self.idealWidth,
            maxWidth: Self.maximumWidth,
            minHeight: isCollapsed ? nil : Self.minimumHeight,
            idealHeight: isCollapsed ? nil : Self.idealHeight,
            maxHeight: isCollapsed ? nil : .infinity
        )
        .background(HostWindowReader(host: hostWindow))
        // After the update that expands the controls, so the window already
        // allows the taller height; content sizing alone would stop at the
        // minimum height.
        .onChange(of: isControlsExpanded) { _, isExpanded in
            guard isExpanded else { return }
            hostWindow.setHeight(expandedHeight > 0 ? expandedHeight : Self.idealHeight)
        }
    }

    /// Whether the controls are collapsed under their heading. A window
    /// with no camera has no heading, so it keeps its usual height.
    private var isCollapsed: Bool {
        session.selectedCamera != nil && !isControlsExpanded
    }

    /// A binding to whether the controls are showing, reporting the
    /// disclosure's own `tap` first.
    ///
    /// The `tap` rides the binding setter, as the sidebar sections' does, so
    /// restoring the window's stored state records no tap nobody made.
    private var controlsExpansion: Binding<Bool> {
        Binding {
            isControlsExpanded
        } set: { isExpanded in
            model.recordTap("compactControls.disclosure", params: ["expanded": .bool(isExpanded)])
            // Read before collapsing, while the window still has its height.
            if !isExpanded, let height = hostWindow.window?.frame.height {
                expandedHeight = height
            }
            isControlsExpanded = isExpanded
        }
    }
}

/// The Controls heading over the compact window's camera controls: the
/// heading and a disclosure chevron, the whole row clickable, as the
/// sidebar's section headings collapse their sections.
private struct ControlsDisclosure: View {
    /// Whether the controls are showing.
    @Binding var isExpanded: Bool

    /// The heading row.
    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                Text("Controls", comment: "Compact window heading that shows or hides the camera's controls")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.default, value: isExpanded)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityValue(
            isExpanded
                ? Text("Expanded", comment: "Accessibility value of the compact window's open Controls heading")
                : Text("Collapsed", comment: "Accessibility value of the compact window's closed Controls heading")
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
