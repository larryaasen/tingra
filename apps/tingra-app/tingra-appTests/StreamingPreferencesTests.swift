//
//  StreamingPreferencesTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

@Suite("StreamingPreferences")
struct StreamingPreferencesTests {
    /// A preferences store over its own throwaway defaults suite, so a test
    /// never reads or writes the user's own settings.
    private func makePreferences() throws -> (StreamingPreferences, UserDefaults, String) {
        let name = "tingra.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (StreamingPreferences(defaults: defaults), defaults, name)
    }

    @Test("a fresh install streams 160 kbps sound")
    func freshInstallAudioBitRate() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(preferences.audioBitsPerSecond == 160_000)
    }

    @Test("a chosen audio bit rate persists and is read back by a fresh store over the same defaults")
    func audioBitRatePersists() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.audioBitsPerSecond = 320_000
        #expect(StreamingPreferences(defaults: defaults).audioBitsPerSecond == 320_000)
    }

    @Test("a stored audio bit rate off the menu reads as the nearest one on it")
    func audioBitRateOffTheMenuSnaps() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(1_000_000, forKey: "streaming.audioBitsPerSecond")
        #expect(preferences.audioBitsPerSecond == 320_000)
    }

    @Test("the stream's rate and the recording's are stored apart")
    func streamAndRecordingRatesAreSeparate() throws {
        let (preferences, defaults, name) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: name) }

        preferences.audioBitsPerSecond = 96_000
        #expect(RecordingPreferences(defaults: defaults).audioBitsPerSecond == 160_000)
    }
}
