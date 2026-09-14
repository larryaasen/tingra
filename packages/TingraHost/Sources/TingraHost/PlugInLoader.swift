//
//  PlugInLoader.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

/// The host's plug-in lifecycle: activates plug-ins against a
/// `PlugInContext` and reports each outcome on the event bus.
///
/// In the CLI era, bundled plug-ins are compiled in but load through this
/// same path the external bundle loader will use (see ARCHITECTURE.md,
/// "Engine model: host and plug-ins").
public struct PlugInLoader: Sendable {
    /// Creates a loader. Stateless — the context carries everything
    /// activation needs.
    public init() {}

    /// The `tier` param on every event this loader emits. The host tier is
    /// the in-process engine; the app tier's loader reports `"app"`.
    static let tier = "host"

    /// Activates each plug-in in order.
    ///
    /// A plug-in that throws is reported as an `error` event and skipped;
    /// the remaining plug-ins load normally — a plug-in must never take
    /// down the host or another plug-in (CLAUDE.md, never-crash rule).
    ///
    /// Both events carry `tier: "host"`: the app emits the same event names
    /// with `tier: "app"` for its out-of-process app-tier plug-ins (see
    /// PLUGINS.md, "Launch on demand"), so a log reader can tell them apart.
    ///
    /// - Returns: The plug-ins that activated successfully.
    @discardableResult
    public func activate(_ plugIns: [any PlugIn], in context: PlugInContext) async -> [any PlugIn] {
        var activated: [any PlugIn] = []
        for plugIn in plugIns {
            do {
                try await plugIn.activate(in: context)
                context.eventBus.event(
                    "plugin.activated",
                    domain: .plugIn,
                    params: [
                        "id": .string(plugIn.id.rawValue),
                        "name": .string(plugIn.name),
                        "tier": .string(Self.tier),
                    ]
                )
                activated.append(plugIn)
            } catch {
                context.eventBus.error(
                    "plugin.activation",
                    domain: .plugIn,
                    params: [
                        "id": .string(plugIn.id.rawValue),
                        "name": .string(plugIn.name),
                        "error": .string(String(describing: error)),
                        "tier": .string(Self.tier),
                    ]
                )
            }
        }
        return activated
    }
}
