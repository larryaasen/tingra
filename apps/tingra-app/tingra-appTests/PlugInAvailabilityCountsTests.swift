//
//  PlugInAvailabilityCountsTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-25.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus

@testable import TingraApp

/// Exercises the counts the app-tier host compares to report
/// `plugin.availability` only when the system's counts change.
@Suite("AppPlugInHost.AvailabilityCounts")
struct PlugInAvailabilityCountsTests {
    @Test("the same counts re-announced compare equal")
    func sameCountsAreEqual() {
        let first = AppPlugInHost.AvailabilityCounts(enabled: 1, disabled: 0, unapproved: 0)
        let again = AppPlugInHost.AvailabilityCounts(enabled: 1, disabled: 0, unapproved: 0)
        #expect(first == again)
    }

    @Test("a change in any count compares unequal")
    func anyChangedCountIsUnequal() {
        let base = AppPlugInHost.AvailabilityCounts(enabled: 1, disabled: 0, unapproved: 0)
        #expect(base != AppPlugInHost.AvailabilityCounts(enabled: 2, disabled: 0, unapproved: 0))
        #expect(base != AppPlugInHost.AvailabilityCounts(enabled: 1, disabled: 1, unapproved: 0))
        #expect(base != AppPlugInHost.AvailabilityCounts(enabled: 1, disabled: 0, unapproved: 1))
    }

    @Test("the event params carry the app tier and each count")
    func paramsCarryTheCounts() {
        let counts = AppPlugInHost.AvailabilityCounts(enabled: 3, disabled: 1, unapproved: 2)
        let expected: [String: EventValue] = [
            "tier": .string("app"), "enabled": .int(3), "disabled": .int(1), "unapproved": .int(2),
        ]
        #expect(counts.params == expected)
    }
}
