//
//  SidebarView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The left selection panel: a standard macOS sidebar listing the saved
/// camera presets (``PresetsSection``), then the available cameras.
///
/// It uses a plain sidebar-styled `List` so the system supplies the Liquid
/// Glass material, section headers, and row metrics; each row is a standard
/// `Label` with an SF Symbol, and the active camera is marked with a trailing
/// checkmark.
///
/// **Every section collapses, and stays that way** — the main Tingra app's
/// sidebar. Each is a `Section` over its own expansion binding, so macOS draws
/// the standard source-list disclosure; which sections are folded away
/// persists in ``SidebarPreferences``.
///
/// **Presets come first**, as they do in the main app: a preset is what the
/// operator reaches for to set a camera up, so it sits above the cameras it
/// recalls settings onto.
struct SidebarView: View {
    /// The shared hardware-selection state driving the active row.
    @Environment(HardwareModel.self) private var model

    /// The sections currently open, seeded from ``SidebarPreferences`` when
    /// the window opens and written back as the operator opens and closes
    /// them.
    ///
    /// Held in `@State` as well as in preferences rather than read straight
    /// from `UserDefaults` through a binding: a binding whose setter only
    /// wrote to the defaults database would publish nothing, so the section
    /// would not redraw around the click that collapsed it.
    @State private var expandedSections: Set<SidebarSection>

    /// Where the open/closed state persists across launches.
    private let preferences: SidebarPreferences

    /// Creates the sidebar.
    ///
    /// - Parameter preferences: Where section expansion persists (the
    ///   standard defaults database by default).
    init(preferences: SidebarPreferences = SidebarPreferences()) {
        self.preferences = preferences
        _expandedSections = State(initialValue: preferences.expandedSections())
    }

    /// Lays out the presets and the cameras in a sidebar list.
    var body: some View {
        List {
            // Above the cameras: a preset recalls settings onto one of them.
            PresetsSection(isExpanded: expansion(of: .presets))

            Section(isExpanded: expansion(of: .cameras)) {
                if model.cameras.isEmpty {
                    Text(
                        "No cameras connected",
                        comment: "Sidebar placeholder when no camera is discovered"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(model.cameras) { camera in
                        DeviceRow(
                            name: camera.name,
                            systemImage: "video",
                            isActive: model.selectedCameraID == camera.id
                        ) {
                            // Selecting a camera switches the live preview to it.
                            model.selectCamera(camera.id)
                        }
                    }
                }
            } header: {
                Text("Cameras")
            }
        }
        .listStyle(.sidebar)
    }

    /// A binding to whether one section is open, reporting the disclosure's
    /// own `tap` and persisting the new state as it changes.
    ///
    /// The `tap` rides the **binding setter** rather than an `onChange`: a
    /// setter runs only when the operator works the control, so restoring the
    /// persisted state when a window opens records no tap nobody made.
    ///
    /// - Parameter section: The section to bind.
    /// - Returns: The binding.
    private func expansion(of section: SidebarSection) -> Binding<Bool> {
        Binding {
            expandedSections.contains(section)
        } set: { isExpanded in
            model.recordTap(section.tapName, params: ["expanded": .bool(isExpanded)])
            if isExpanded {
                expandedSections.insert(section)
            } else {
                expandedSections.remove(section)
            }
            preferences.setExpanded(isExpanded, for: section)
        }
    }
}

/// One tappable device row: a standard `Label` (SF Symbol + name) that marks
/// itself active with a trailing checkmark.
private struct DeviceRow: View {
    /// The device name shown in the row.
    let name: String
    /// The SF Symbol identifying the device (`video` for a camera).
    let systemImage: String
    /// Whether this row is the active selection.
    let isActive: Bool
    /// Invoked when the row is activated, to update the selection.
    let onSelect: () -> Void

    /// Draws the label-plus-checkmark row as a borderless button.
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Label(name, systemImage: systemImage)
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#Preview {
    NavigationSplitView {
        SidebarView()
            .environment(HardwareModel.preview)
    } detail: {
        Color.clear
    }
    .frame(width: 900, height: 560)
}

#Preview {
    NavigationSplitView {
        SidebarView()
            .environment(HardwareModel.preview)
    } detail: {
        Color.clear
    }
    .frame(width: 900, height: 560)
}
