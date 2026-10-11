//
//  PlugInDiscoveryPlanTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

/// Exercises how the app-tier host reads a batch from the system's discovery
/// stream, over a stand-in identity (an `Int`), since ExtensionKit's own
/// cannot be constructed in a test.
@Suite("PlugInDiscoveryPlan")
struct PlugInDiscoveryPlanTests {
    /// The plan over the stand-in identity.
    private typealias Plan = PlugInDiscoveryPlan<Int>

    /// The Notes extension's bundle identifier.
    private let notes = "com.moonwink.tingra.app.notes"

    /// A second extension's bundle identifier.
    private let other = "com.example.other"

    @Test("an extension delivered again under the same identity changes nothing")
    func sameIdentityChangesNothing() {
        let plan = Plan(
            registered: [.init(bundleIdentifier: notes, identity: 1)],
            batch: [.init(bundleIdentifier: notes, identity: 1)])
        #expect(plan.isEmpty)
    }

    @Test("an extension delivered again under an unequal identity is refreshed, not registered a second time")
    func unequalIdentityIsRefreshed() {
        let plan = Plan(
            registered: [.init(bundleIdentifier: notes, identity: 1)],
            batch: [.init(bundleIdentifier: notes, identity: 2)])
        #expect(plan.refreshed == [.init(bundleIdentifier: notes, identity: 2)])
        #expect(plan.arrived.isEmpty)
        #expect(plan.retired.isEmpty)
        #expect(!plan.isEmpty)
    }

    @Test("an extension not yet registered arrives")
    func newExtensionArrives() {
        let plan = Plan(
            registered: [.init(bundleIdentifier: notes, identity: 1)],
            batch: [.init(bundleIdentifier: notes, identity: 1), .init(bundleIdentifier: other, identity: 7)])
        #expect(plan.arrived == [.init(bundleIdentifier: other, identity: 7)])
        #expect(plan.refreshed.isEmpty)
        #expect(plan.retired.isEmpty)
    }

    @Test("a registered extension the batch no longer lists is retired")
    func missingExtensionIsRetired() {
        let plan = Plan(
            registered: [.init(bundleIdentifier: notes, identity: 1), .init(bundleIdentifier: other, identity: 7)],
            batch: [.init(bundleIdentifier: other, identity: 7)])
        #expect(plan.retired == [notes])
        #expect(plan.refreshed.isEmpty)
        #expect(plan.arrived.isEmpty)
    }

    @Test("an empty batch retires every registered extension, in registration order")
    func emptyBatchRetiresAll() {
        let plan = Plan(
            registered: [.init(bundleIdentifier: notes, identity: 1), .init(bundleIdentifier: other, identity: 7)],
            batch: [])
        #expect(plan.retired == [notes, other])
    }

    @Test("an empty batch with nothing registered changes nothing")
    func nothingToNothing() {
        #expect(Plan(registered: [], batch: []).isEmpty)
    }

    @Test("one batch can retire, refresh, and bring an arrival at once")
    func everyChangeTogether() {
        let third = "com.example.third"
        let plan = Plan(
            registered: [.init(bundleIdentifier: notes, identity: 1), .init(bundleIdentifier: other, identity: 7)],
            batch: [.init(bundleIdentifier: third, identity: 9), .init(bundleIdentifier: notes, identity: 2)])
        #expect(plan.retired == [other])
        #expect(plan.refreshed == [.init(bundleIdentifier: notes, identity: 2)])
        #expect(plan.arrived == [.init(bundleIdentifier: third, identity: 9)])
    }

    @Test("a bundle identifier listed twice in one batch counts once, by its first entry")
    func duplicateInBatchCountsOnce() {
        let arriving = Plan(
            registered: [],
            batch: [.init(bundleIdentifier: notes, identity: 1), .init(bundleIdentifier: notes, identity: 2)])
        #expect(arriving.arrived == [.init(bundleIdentifier: notes, identity: 1)])

        let held = Plan(
            registered: [.init(bundleIdentifier: notes, identity: 1)],
            batch: [.init(bundleIdentifier: notes, identity: 1), .init(bundleIdentifier: notes, identity: 2)])
        #expect(held.isEmpty)
    }

    @Test("plans compare equal when every list matches, and unequal when one differs")
    func equality() {
        let registered: [Plan.Entry] = [.init(bundleIdentifier: notes, identity: 1)]
        let refreshed = Plan(registered: registered, batch: [.init(bundleIdentifier: notes, identity: 2)])
        #expect(refreshed == Plan(registered: registered, batch: [.init(bundleIdentifier: notes, identity: 2)]))
        #expect(refreshed != Plan(registered: registered, batch: [.init(bundleIdentifier: notes, identity: 3)]))
        #expect(refreshed != Plan(registered: registered, batch: []))
        #expect(Plan.Entry(bundleIdentifier: notes, identity: 1) != Plan.Entry(bundleIdentifier: other, identity: 1))
    }
}
