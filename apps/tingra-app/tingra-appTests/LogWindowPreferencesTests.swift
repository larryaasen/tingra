//
//  LogWindowPreferencesTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraHost

@testable import TingraApp

@Suite("LogWindowPreferences")
struct LogWindowPreferencesTests {
    /// Runs `body` against a fresh defaults suite, removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "LogWindowPreferencesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test("a fresh install shows every level, taps, and every launch")
    func defaults() throws {
        try withDefaults { defaults in
            let preferences = LogWindowPreferences(defaults: defaults)
            #expect(preferences.levels == Set(LogLevel.allCases))
            #expect(preferences.showsTaps)
            #expect(preferences.launch == .all)
        }
    }

    @Test("stored choices read back, including every level hidden and taps hidden")
    func roundTrip() throws {
        try withDefaults { defaults in
            let preferences = LogWindowPreferences(defaults: defaults)
            preferences.levels = [.debug, .error]
            preferences.showsTaps = false
            preferences.launch = .current

            let reread = LogWindowPreferences(defaults: defaults)
            #expect(reread.levels == [.debug, .error])
            #expect(!reread.showsTaps)
            #expect(reread.launch == .current)

            preferences.levels = []
            #expect(reread.levels.isEmpty)
        }
    }

    @Test("unrecognizable stored values read as the defaults rather than trapping")
    func unknownValues() throws {
        try withDefaults { defaults in
            defaults.set(["INFO", "NOTICE"], forKey: "logWindow.levels")
            defaults.set("yesterday", forKey: "logWindow.launch")
            let preferences = LogWindowPreferences(defaults: defaults)
            #expect(preferences.levels == [.info])
            #expect(preferences.launch == .all)
        }
    }
}
