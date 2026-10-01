//
//  PlugInAvailabilityCountsTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-25.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
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

    @Test("the extensions that are off are the disabled and the unapproved ones together")
    func offCountsDisabledAndUnapproved() {
        #expect(AppPlugInHost.AvailabilityCounts(enabled: 3, disabled: 1, unapproved: 2).off == 3)
        #expect(AppPlugInHost.AvailabilityCounts(enabled: 1, disabled: 0, unapproved: 0).off == 0)
    }

    @Test("an extension inside the app's extensions folder is embedded; one elsewhere is not")
    func embeddedExtension() {
        let folder = URL(filePath: "/Applications/Tingra.app/Contents/Extensions", directoryHint: .isDirectory)
        #expect(
            AppPlugInHost.isEmbedded(
                URL(filePath: "/Applications/Tingra.app/Contents/Extensions/TingraNotes.appex"), in: folder))
        #expect(
            !AppPlugInHost.isEmbedded(
                URL(filePath: "/Applications/Other.app/Contents/Extensions/Pane.appex"), in: folder))
        #expect(!AppPlugInHost.isEmbedded(folder, in: folder))
        #expect(
            !AppPlugInHost.isEmbedded(
                URL(filePath: "/Applications/Tingra.app/Contents/ExtensionsElsewhere/Pane.appex"), in: folder))
    }
}
