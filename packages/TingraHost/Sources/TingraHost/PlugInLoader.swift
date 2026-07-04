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

    /// Activates each plug-in in order.
    ///
    /// A plug-in that throws is reported as an `error` event and skipped;
    /// the remaining plug-ins load normally — a plug-in must never take
    /// down the host or another plug-in (CLAUDE.md, never-crash rule).
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
                    ]
                )
            }
        }
        return activated
    }
}
