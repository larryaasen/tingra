//
//  StallReporter.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

/// Turns a per-tick synthesis failure into control-plane events, by reporting
/// the *episode* rather than each occurrence — the rule in EVENTS.md,
/// "Reporting a repeating failure".
///
/// A generator that cannot synthesize usually cannot synthesize on every tick,
/// so reporting each failure would put one error per frame on the bus, which
/// principle 3 forbids. Reporting nothing, which is what the generators did
/// before, is worse: the input goes quiet and looks like a hang. So exactly
/// two events bound an episode however long it lasts — `generator.stalled`
/// when output stops, `generator.resumed` when it comes back, carrying how
/// many ticks were lost.
///
/// One reporter belongs to one stream's synthesis task and is driven only
/// from inside it, so it is a plain mutable struct with no synchronization.
struct StallReporter {
    /// The generator whose output stopped, reported with every event.
    private let inputID: InputID

    /// The bus to report on; nil in tests and anywhere diagnostics are not
    /// wanted, in which case the reporter tracks nothing and emits nothing.
    private let eventBus: EventBus?

    /// The failure that opened the current episode, or nil while output is
    /// flowing. Holding the *first* cause is what keeps a changing cause from
    /// reopening the report — see the type documentation.
    private var openedBy: GeneratorSynthesisFailure?

    /// Ticks skipped since the current episode opened.
    private var skipped = 0

    /// Creates a reporter for one stream.
    ///
    /// - Parameters:
    ///   - inputID: The generator's identifier.
    ///   - eventBus: The host's event bus, or nil to report nothing.
    init(inputID: InputID, eventBus: EventBus?) {
        self.inputID = inputID
        self.eventBus = eventBus
    }

    /// Records a tick that produced output, closing any open episode with a
    /// `generator.resumed` event. Does nothing while output is already
    /// flowing, which is the overwhelmingly common path.
    mutating func recordOutput() {
        guard let openedBy else { return }
        eventBus?.event(
            "generator.resumed",
            domain: .capture,
            params: [
                "id": .string(inputID.rawValue),
                "reason": .string(openedBy.reason),
                "skipped": .int(skipped),
            ]
        )
        self.openedBy = nil
        skipped = 0
    }

    /// Records a tick that produced nothing, opening an episode with a
    /// `generator.stalled` event if one is not open already.
    ///
    /// - Parameter failure: Why this tick produced nothing.
    mutating func recordFailure(_ failure: GeneratorSynthesisFailure) {
        skipped += 1
        guard openedBy == nil else { return }
        openedBy = failure
        var params: [String: EventValue] = [
            "id": .string(inputID.rawValue),
            "reason": .string(failure.reason),
        ]
        if let status = failure.status {
            params["status"] = .int(Int(status))
        }
        eventBus?.error("generator.stalled", domain: .capture, params: params)
    }
}
