//
//  ApplicationChoiceTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraCapturePlugIns
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

@Suite("ApplicationChoice")
struct ApplicationChoiceTests {
    /// An application the picker lists.
    private let music = CaptureApplication(bundleIdentifier: "com.example.music", name: "Music Maker")

    @Test("a picked application becomes a record with its bundle identifier, its name, and a fresh identity")
    func record() {
        let first = ApplicationChoice.record(for: music)
        let second = ApplicationChoice.record(for: music)
        #expect(first.bundleIdentifier == "com.example.music")
        #expect(first.name == "Music Maker")
        #expect(first.id != second.id)
    }

    @Test("a record gives back the application the capture looks for")
    func application() {
        let record = ProjectApplication(
            id: InputID(rawValue: "a"), bundleIdentifier: "com.example.music", name: "Music Maker")
        #expect(ApplicationChoice.application(of: record) == music)
    }

    @Test("an application is added when a record has its bundle identifier, whatever its name")
    func isAdded() {
        let renamed = ProjectApplication(bundleIdentifier: "com.example.music", name: "Music Maker 2")
        let other = ProjectApplication(bundleIdentifier: "com.example.other", name: "Music Maker")
        #expect(ApplicationChoice.isAdded(music, to: [renamed]))
        #expect(!ApplicationChoice.isAdded(music, to: [other]))
        #expect(!ApplicationChoice.isAdded(music, to: []))
    }
}
