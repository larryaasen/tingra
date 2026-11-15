//
//  MonitorOverlayMenu.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus
import TingraPlugInKit

/// A monitor's monitor overlays as a submenu of checkable items
/// (PLUGINS.md, Decision 57): one section per stage, picture overlays
/// first, then guides, each in the catalog's order. An overlay with nothing
/// to show on that monitor is disabled but keeps its checkmark, since it
/// stays on in the project. **Overlay Settings…** ends it, opening the
/// window that edits every overlay's values (``MonitorOverlaySettingsView``).
/// Used by every monitor's context menu as **Overlays**, and by the
/// Program menu as **Program Overlays** and **Preview Overlays**.
struct MonitorOverlayMenu: View {
    /// The model the items read and change the project's overlays through.
    let model: EngineModel

    /// The monitor the items are for.
    let target: MonitorOverlayTarget

    /// The `tap` each item reports before it changes anything, with the
    /// monitor, the overlay, and the new state as params.
    let tapName: String

    /// The submenu's title.
    let title: Text

    /// Opens the Overlay Settings window.
    @Environment(\.openWindow) private var openWindow

    /// The submenu.
    var body: some View {
        Menu {
            if model.monitorOverlayCatalog.providers.isEmpty {
                // A bare text in a menu is drawn as a disabled item.
                Text(
                    "No Overlays",
                    comment: "Disabled item in a monitor's Overlays submenu when no monitor overlay is registered")
            }
            ForEach(model.monitorOverlayCatalog.sections) { section in
                Section {
                    ForEach(section.providers, id: \.id) { provider in
                        Toggle(isOn: binding(for: provider.id)) {
                            Text(provider.name)
                        }
                        .disabled(!model.isMonitorOverlayAvailable(provider, on: target))
                    }
                }
            }
            Divider()
            Button {
                model.eventBus.tap(
                    "monitorOverlaySettings.menuItem", domain: .composition, params: ["monitor": target.eventValue])
                openWindow(id: TingraApp.overlaySettingsWindowID)
            } label: {
                Text(
                    "Overlay Settings…",
                    comment:
                        "Last item of a monitor's Overlays submenu: opens the window editing the overlays' settings"
                )
            }
        } label: {
            title
        }
    }

    /// One item's checkmark: on while the project shows the overlay on this
    /// monitor; setting it reports the `tap`, then turns the overlay on or
    /// off.
    ///
    /// - Parameter id: The item's overlay.
    /// - Returns: The binding.
    private func binding(for id: MonitorOverlayID) -> Binding<Bool> {
        Binding {
            model.isMonitorOverlayOn(id, on: target)
        } set: { isOn in
            model.eventBus.tap(
                tapName, domain: .composition,
                params: ["monitor": target.eventValue, "overlay": .string(id.rawValue), "isOn": .bool(isOn)])
            model.setMonitorOverlay(id, on: target, isOn: isOn)
        }
    }
}
