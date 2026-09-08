//
//  AppDataModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Observation
import TingraEventBus

/// The model behind the Data settings pane: the inventory of what Tingra has
/// saved on this Mac, and the one action that removes it.
///
/// **Refreshed on events, never polled** (CLAUDE.md): the inventory is read
/// when the pane appears and again after a removal — the two moments the
/// pane is looking and the answer can have changed. Nothing else in the app
/// writes to disk while the operator reads a settings pane that a refresh
/// on appearing would miss by more than one autosave.
///
/// The `@Observable` rule: `@MainActor`, owned by the ``EngineModel``, read
/// by the pane.
@MainActor
@Observable
final class AppDataModel {
    /// What is saved, one item per kind, as of the last ``refresh()``.
    private(set) var items: [AppDataItem] = []

    /// The kinds the last ``removeAll()`` could not remove; empty before a
    /// removal and after one that removed everything.
    private(set) var failures: [AppDataRemovalFailure] = []

    /// Where the data is and how to remove it.
    @ObservationIgnored private let store: AppDataStore

    /// The host's event bus, for the `appdata.*` events.
    @ObservationIgnored private let eventBus: EventBus

    /// Creates the model over a store.
    ///
    /// - Parameters:
    ///   - store: Where the data is and how to remove it.
    ///   - eventBus: The host's event bus.
    init(store: AppDataStore, eventBus: EventBus) {
        self.store = store
        self.eventBus = eventBus
    }

    /// Re-reads the inventory.
    func refresh() {
        items = store.inventory()
    }

    /// Removes every removable kind, reports the outcome on the bus, and
    /// re-reads the inventory so the pane shows what is left.
    ///
    /// One `appdata.removed` event carries what was removed — the count of
    /// each kind as it stood before, so a session log says what a reset
    /// cleared — and each kind that could not be removed is an
    /// `appdata.remove` error naming the kind and the reason. Counts only:
    /// no path of the operator's and never a secret becomes a param
    /// (EVENTS.md).
    ///
    /// - Returns: Whether everything was removed.
    @discardableResult
    func removeAll() -> Bool {
        let before = store.inventory()
        failures = store.removeAll()
        let failed = Set(failures.map(\.kind))
        var params: [String: EventValue] = [:]
        for item in before where item.kind.isRemovable && !failed.contains(item.kind) {
            params[item.kind.rawValue] = .int(item.count)
        }
        eventBus.event("appdata.removed", domain: .platform, params: params)
        for failure in failures {
            eventBus.error(
                "appdata.remove",
                domain: .platform,
                params: ["kind": .string(failure.kind.rawValue), "error": .string(failure.reason)]
            )
        }
        refresh()
        return failures.isEmpty
    }
}
