//
//  PlugInEnablementModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-30.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// The model behind the Plug-ins settings pane's toggles: which installed
/// plug-ins are turned off, read from and written to `plug-ins.json`, the
/// operator-wide file every front end's bundle loader reads (PLUGINS.md,
/// Decisions 34 and 36).
///
/// **Read when the pane appears, never polled** (CLAUDE.md): `tingra-cli
/// plug-ins enable|disable` can change the file while the app runs, and the
/// pane appearing is the moment that answer matters. Every read goes to the
/// file, the store's own rule, so a toggle never writes back a stale record.
///
/// A change takes effect at the next launch (Decision 27), so the model only
/// records the choice; the pane says so on the row.
@MainActor
@Observable
final class PlugInEnablementModel {
    /// The record as of the last read or write.
    private(set) var enablement = PlugInEnablement()

    /// Why the file could not be read or written, as its message, or `nil`
    /// when the last read or write went through. While the file cannot be
    /// read the pane offers no toggle: the store never overwrites a file it
    /// cannot read.
    private(set) var problem: String?

    /// Whether the last read could not parse the file, which rules out
    /// writing to it.
    private(set) var isUnreadable = false

    /// Where the record lives.
    @ObservationIgnored private let store: PlugInEnablementStore

    /// The host's event bus, for the `plugin.enablementChanged` event and
    /// the `plugin.enablement` error.
    @ObservationIgnored private let eventBus: EventBus

    /// Creates the model over a store.
    ///
    /// - Parameters:
    ///   - store: Where the record lives (Tingra's Application Support
    ///     folder in the app; a temporary folder in tests).
    ///   - eventBus: The host's event bus.
    init(store: PlugInEnablementStore, eventBus: EventBus) {
        self.store = store
        self.eventBus = eventBus
    }

    /// Re-reads the file.
    func refresh() {
        do {
            enablement = try store.read()
            problem = nil
            isUnreadable = false
        } catch {
            problem = String(describing: error)
            isUnreadable = true
        }
    }

    /// Whether a plug-in's bundle is on: neither the operator nor a crash
    /// turned it off.
    ///
    /// - Parameter id: The plug-in.
    func isOn(_ id: PlugInID) -> Bool {
        !enablement.isDisabled(id) && enablement.crash(of: id) == nil
    }

    /// Whether a crash turned a plug-in's bundle off (Decision 33).
    ///
    /// - Parameter id: The plug-in.
    func isCrashed(_ id: PlugInID) -> Bool {
        enablement.crash(of: id) != nil
    }

    /// Turns a plug-in's bundle on or off for the next launch, and reports
    /// the change as `plugin.enablementChanged`. Turning one on also forgets
    /// a crash that turned it off, as `tingra-cli plug-ins enable` does.
    ///
    /// A file that cannot be read or written is a `plugin.enablement`
    /// error, and the model keeps the message for the pane.
    ///
    /// - Parameters:
    ///   - isOn: Whether the bundle loads at the next launch.
    ///   - id: The plug-in.
    func setOn(_ isOn: Bool, for id: PlugInID) {
        do {
            enablement = try store.update { enablement in
                if isOn { enablement.enable(id) } else { enablement.disable(id) }
            }
            problem = nil
            isUnreadable = false
            eventBus.event(
                "plugin.enablementChanged", domain: .plugIn,
                params: ["id": .string(id.rawValue), "enabled": .bool(isOn), "tier": .string("host")])
        } catch {
            problem = String(describing: error)
            if case PlugInEnablementStoreError.unreadable = error { isUnreadable = true }
            eventBus.error(
                "plugin.enablement", domain: .plugIn,
                params: ["id": .string(id.rawValue), "error": .string(String(describing: error))])
        }
    }
}
