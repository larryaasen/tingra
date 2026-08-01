//
//  TapReportingBindingTests.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import Synchronization
import Testing
import TingraEventBus

@testable import Tingra

@Suite("Binding.reportingTap")
struct TapReportingBindingTests {
    /// Collects every event the bus carries while a body runs, so a test can
    /// assert on what was — and was not — reported.
    private func recordedEvents(during body: (EventBus) -> Void) async -> [EventBusEvent] {
        let bus = EventBus()
        let stream = bus.events()
        body(bus)
        bus.shutdown()
        var events: [EventBusEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("a user edit through the binding reports the tap, then writes the value through")
    func userEditReportsTheTap() async {
        let box = ValueBox("before")
        let events = await recordedEvents { bus in
            let binding = box.binding.reportingTap(to: bus, "camera.picker", domain: .capture) {
                ["id": .string($0)]
            }
            binding.wrappedValue = "after"
        }

        #expect(box.value == "after")
        let taps = events.filter { $0.group == .tap }
        #expect(taps.count == 1)
        #expect(taps.first?.name == "camera.picker")
        #expect(taps.first?.domain == .capture)
        #expect(taps.first?.params?["id"] == .string("after"))
    }

    @Test("a programmatic assignment to the underlying value reports nothing")
    func programmaticAssignmentIsSilent() async {
        // The whole point of the helper: the model assigning a default during
        // boot is not a user action, and an `onChange` handler could not tell
        // the two apart (EVENTS.md — a tap records that the operator acted).
        let box = ValueBox("before")
        let events = await recordedEvents { bus in
            _ = box.binding.reportingTap(to: bus, "camera.picker", domain: .capture) { ["id": .string($0)] }
            box.value = "assigned by the model"
        }

        #expect(box.value == "assigned by the model")
        #expect(events.filter { $0.group == .tap }.isEmpty)
    }

    @Test("reading the binding reports nothing — only a write is a user action")
    func readingIsSilent() async {
        let box = ValueBox("value")
        let events = await recordedEvents { bus in
            let binding = box.binding.reportingTap(to: bus, "camera.picker", domain: .capture)
            #expect(binding.wrappedValue == "value")
        }

        #expect(events.filter { $0.group == .tap }.isEmpty)
    }

    @Test("a tap carries no params when the caller declares none")
    func paramsDefaultToNone() async {
        let box = ValueBox("before")
        let events = await recordedEvents { bus in
            let binding = box.binding.reportingTap(to: bus, "transition.picker", domain: .composition)
            binding.wrappedValue = "after"
        }

        let tap = events.first { $0.group == .tap }
        #expect(tap?.name == "transition.picker")
        #expect(tap?.params == nil)
    }

    /// A stand-in for the observable model a real picker binds into: a
    /// reference box, so a binding over it can be written through and the
    /// result read back.
    ///
    /// Genuinely `Sendable` over a `Mutex` rather than `@unchecked` —
    /// SwiftUI's binding setter is `@Sendable`, and the two frame wrappers
    /// remain the codebase's only sanctioned unchecked conformances
    /// (ARCHITECTURE.md, "Frame ownership across the `Input` seam").
    private final class ValueBox: Sendable {
        /// The stored value.
        private let storage: Mutex<String>

        /// Creates a box holding a value.
        init(_ value: String) {
            storage = Mutex(value)
        }

        /// The stored value, read and written under the lock.
        var value: String {
            get { storage.withLock { $0 } }
            set { storage.withLock { $0 = newValue } }
        }

        /// A plain read-write binding into ``value``.
        var binding: Binding<String> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }
}
