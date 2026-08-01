//
//  TapReportingBinding.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

extension Binding where Value: Sendable {
    /// The same binding, reporting a `tap` event before a **user edit**
    /// lands.
    ///
    /// A `tap` records that *the operator acted* (EVENTS.md, "The `tap`
    /// convention") — kept deliberately separate from the event the action
    /// then causes, which is what makes the bus a faithful enough record to
    /// replay a show from. Reporting one from `onChange` cannot honour that:
    /// the handler sees only that the value changed, so it fires just as
    /// readily when the model assigns a default during boot, recording a tap
    /// with no user involved.
    ///
    /// A control's binding setter can tell the difference — SwiftUI calls it
    /// only when the control itself is operated, never when the underlying
    /// value changes underneath it. So the **tap** belongs here, and the
    /// **effect** of the change stays in `onChange`, where it correctly runs
    /// however the value changed.
    ///
    /// - Parameters:
    ///   - eventBus: The bus the tap goes to.
    ///   - name: The control's tap name — per control, never per screen
    ///     (CLAUDE.md).
    ///   - domain: The emitting area.
    ///   - params: The tap's params, built from the value the operator chose.
    ///     Defaults to none. `@Sendable` because SwiftUI's binding setter is,
    ///     so a caller needing a name from an observable list snapshots that
    ///     list into the closure rather than capturing the model — which also
    ///     makes the tap name the list the picker was actually showing.
    /// - Returns: A binding that reports the tap, then writes through.
    func reportingTap(
        to eventBus: EventBus,
        _ name: String,
        domain: EventDomain,
        params: @escaping @Sendable (Value) -> [String: EventValue]? = { _ in nil }
    ) -> Binding<Value> {
        Binding {
            wrappedValue
        } set: { newValue in
            eventBus.tap(name, domain: domain, params: params(newValue))
            self.wrappedValue = newValue
        }
    }
}
