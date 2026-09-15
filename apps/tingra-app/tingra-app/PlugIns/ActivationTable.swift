//
//  ActivationTable.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAppPlugInKit
import TingraEventBus
import TingraPlugInKit

/// The activation conditions every discovered app-tier plug-in declared,
/// indexed by event name so that each event drained from the bus costs one
/// dictionary lookup rather than a scan of every manifest (PLUGINS.md,
/// Phase 2, "Activation conditions"). `AppPlugInHost` fills it at discovery
/// and asks it about every bus event; a match is the plug-in to wake and
/// the condition that woke it.
struct ActivationTable {
    /// A plug-in an event woke, with the condition it met.
    struct Match: Equatable {
        /// The plug-in.
        let plugIn: PlugInID

        /// The condition the event met — the first of the plug-in's, in
        /// manifest order, when several do.
        let condition: ActivationCondition
    }

    /// The conditions by event name, each with its plug-in, in registration
    /// order.
    private var conditions: [String: [(plugIn: PlugInID, condition: ActivationCondition)]] = [:]

    /// Creates an empty table.
    init() {}

    /// Whether no plug-in has declared a condition.
    var isEmpty: Bool { conditions.isEmpty }

    /// Adds a plug-in's conditions.
    ///
    /// - Parameters:
    ///   - declared: The conditions the manifest lists.
    ///   - plugIn: The plug-in.
    mutating func add(_ declared: [ActivationCondition], for plugIn: PlugInID) {
        for condition in declared {
            conditions[condition.event, default: []].append((plugIn, condition))
        }
    }

    /// Removes every condition a plug-in declared (the plug-in was disabled
    /// or removed).
    ///
    /// - Parameter plugIn: The plug-in.
    mutating func removeAll(for plugIn: PlugInID) {
        for (event, entries) in conditions {
            let remaining = entries.filter { $0.plugIn != plugIn }
            conditions[event] = remaining.isEmpty ? nil : remaining
        }
    }

    /// The plug-ins an event wakes, in the order they registered, each once
    /// however many of its conditions the event meets.
    ///
    /// - Parameter event: An event drained from the bus.
    func matches(_ event: EventBusEvent) -> [Match] {
        guard let candidates = conditions[event.name] else { return [] }
        var woken = Set<PlugInID>()
        var matches: [Match] = []
        for entry in candidates where entry.condition.matches(event) {
            guard woken.insert(entry.plugIn).inserted else { continue }
            matches.append(Match(plugIn: entry.plugIn, condition: entry.condition))
        }
        return matches
    }
}
