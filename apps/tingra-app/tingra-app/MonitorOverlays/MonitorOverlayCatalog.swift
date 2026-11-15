//
//  MonitorOverlayCatalog.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import TingraMonitorPlugIns
import TingraPlugInKit

/// Every registered monitor overlay, in the order the Overlays submenus
/// list them (PLUGINS.md, Decision 57): the first-party overlays in their
/// fixed order, then every other overlay by name. A main-actor snapshot of
/// the host's `MonitorOverlayRegistry`, taken once the plug-ins have
/// activated, like the effect choices, so a menu and a draw never await
/// an actor.
struct MonitorOverlayCatalog {
    /// One menu section: the overlays of one stage.
    struct Section: Identifiable {
        /// The stage the section holds.
        let stage: MonitorOverlayStage

        /// The section's overlays, in menu order.
        let providers: [any MonitorOverlayProvider]

        /// The stage identifies the section.
        var id: MonitorOverlayStage { stage }
    }

    /// The providers, in menu order.
    let providers: [any MonitorOverlayProvider]

    /// An empty catalog: no overlays registered yet.
    static let empty = MonitorOverlayCatalog(providers: [])

    /// Creates a catalog, ordering the providers for the menus.
    ///
    /// - Parameters:
    ///   - providers: The registered providers, in any order.
    ///   - firstPartyOrder: The first-party overlays' fixed order (default:
    ///     the first-party plug-in's).
    init(providers: [any MonitorOverlayProvider], firstPartyOrder: [MonitorOverlayID] = MonitorPlugIn.overlayIDs) {
        let rank = Dictionary(uniqueKeysWithValues: firstPartyOrder.enumerated().map { ($1, $0) })
        self.providers = providers.sorted { lhs, rhs in
            switch (rank[lhs.id], rank[rhs.id]) {
            case (let left?, let right?): left < right
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// The provider with an id, if one is registered.
    ///
    /// - Parameter id: The overlay's identifier.
    /// - Returns: The provider, or `nil` for an overlay whose plug-in is
    ///   not loaded.
    func provider(withID id: MonitorOverlayID) -> (any MonitorOverlayProvider)? {
        providers.first { $0.id == id }
    }

    /// The menu's sections: picture overlays, then guides, each only when
    /// it has an overlay, in the order a monitor draws them.
    var sections: [Section] {
        MonitorOverlayStage.allCases.compactMap { stage in
            let members = providers.filter { $0.stage == stage }
            return members.isEmpty ? nil : Section(stage: stage, providers: members)
        }
    }

    /// The overlays a monitor draws for a list of ids: those this build has
    /// a provider for, in drawing order (every picture overlay before any
    /// guide, then menu order), each made with its stored values.
    ///
    /// - Parameters:
    ///   - ids: The ids on for the monitor, in any order.
    ///   - parameters: The stored values, keyed by overlay id.
    /// - Returns: The overlays to draw, with their providers.
    func overlays(
        for ids: [MonitorOverlayID], parameters: [String: [String: JSONValue]]
    ) -> [MonitorOverlayLineup.Entry] {
        let wanted = Set(ids)
        return sections.flatMap(\.providers)
            .filter { wanted.contains($0.id) }
            .map { provider in
                let values = parameters[provider.id.rawValue] ?? [:]
                return MonitorOverlayLineup.Entry(
                    provider: provider, overlay: provider.makeOverlay(parameters: values), parameters: values)
            }
    }
}
