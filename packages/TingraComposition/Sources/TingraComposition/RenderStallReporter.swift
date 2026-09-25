//
//  RenderStallReporter.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-09-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus

/// Turns the compositor's per-tick render failures into control-plane
/// events by reporting the *episode* rather than each skipped tick — the
/// rule in EVENTS.md, "Reporting a repeating failure", as the generators
/// apply it with their own stall reporter.
///
/// A renderer that cannot produce a frame (an exhausted `IOSurface` budget,
/// say) usually cannot on every tick, so an error per skipped tick would put
/// one event per frame on the bus, which the control-plane rule forbids;
/// reporting nothing leaves a frozen program with no explanation. So exactly
/// two events bound an episode however long it lasts — `<bus>.stalled` (an
/// `error`) on the first skipped tick and `<bus>.resumed` on the first tick
/// that renders again, carrying how many ticks were lost.
///
/// Tracking is per bus: program and preview render in separate passes, so
/// each has its own reporter and stalls and recovers on its own. Both live
/// inside the compositor's tick task and are driven only from it, so this is
/// a plain mutable struct with no synchronization.
struct RenderStallReporter {
    /// The bus the reporter speaks for — `program` or `preview` — used as the
    /// event name's prefix.
    private let bus: String

    /// The host's event bus the episode is reported on.
    private let eventBus: EventBus

    /// The failure that opened the current episode, or nil while frames are
    /// rendering. Holding the *first* cause keeps a changing cause from
    /// reopening the report.
    private var openedBy: ShotRenderFailure?

    /// Ticks skipped since the current episode opened.
    private var skipped = 0

    /// Creates a reporter for one bus.
    ///
    /// - Parameters:
    ///   - bus: The event name prefix, `program` or `preview`.
    ///   - eventBus: The host's event bus.
    init(bus: String, eventBus: EventBus) {
        self.bus = bus
        self.eventBus = eventBus
    }

    /// Records a tick that rendered, closing any open episode with a
    /// `<bus>.resumed` event. Does nothing while frames are already
    /// rendering, which is the overwhelmingly common path.
    mutating func recordOutput() {
        guard let openedBy else { return }
        eventBus.event(
            "\(bus).resumed",
            domain: .composition,
            params: [
                "reason": .string(openedBy.reason),
                "skipped": .int(skipped),
            ]
        )
        self.openedBy = nil
        skipped = 0
    }

    /// Records a tick that rendered nothing, opening an episode with a
    /// `<bus>.stalled` error if one is not open already.
    ///
    /// - Parameter failure: Why this tick rendered nothing.
    mutating func recordFailure(_ failure: ShotRenderFailure) {
        skipped += 1
        guard openedBy == nil else { return }
        openedBy = failure
        eventBus.error(
            "\(bus).stalled",
            domain: .composition,
            params: [
                "reason": .string(failure.reason),
                "status": .int(failure.status),
            ]
        )
    }
}
