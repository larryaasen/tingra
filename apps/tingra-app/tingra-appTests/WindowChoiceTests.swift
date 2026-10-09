//
//  WindowChoiceTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraCapturePlugIns
import TingraComposition
import TingraPlugInKit

@testable import TingraApp

/// Exercises the rules between the picker's windows, the project's records,
/// and the capture's targets (ARCHITECTURE.md, "Window capture").
@Suite("WindowChoice")
struct WindowChoiceTests {
    /// Makes a window as the picker lists it.
    private func window(
        _ id: UInt32,
        bundle: String = "com.apple.Keynote",
        application: String = "Keynote",
        title: String,
        width: Double = 1280,
        height: Double = 720
    ) -> CaptureWindow {
        CaptureWindow(
            id: id,
            target: WindowTarget(bundleIdentifier: bundle, applicationName: application, title: title),
            width: width,
            height: height,
            isOnScreen: true
        )
    }

    @Test("a picked window becomes a record carrying its application and title under a fresh identity")
    func recordForWindow() {
        let picked = window(7, title: "Launch Deck")
        let first = WindowChoice.record(for: picked)
        let second = WindowChoice.record(for: picked)
        #expect(first.bundleIdentifier == "com.apple.Keynote")
        #expect(first.applicationName == "Keynote")
        #expect(first.title == "Launch Deck")
        #expect(first.id != second.id)
    }

    @Test("a record's target is the window's own, so the two describe the same window")
    func targetOfRecord() {
        let picked = window(7, title: "Launch Deck")
        #expect(WindowChoice.target(of: WindowChoice.record(for: picked)) == picked.target)
    }

    @Test("a window is added when a record has its application and title, whatever its identifier")
    func isAdded() {
        let records = [WindowChoice.record(for: window(7, title: "Launch Deck"))]
        #expect(WindowChoice.isAdded(window(99, title: "Launch Deck"), to: records))
        #expect(!WindowChoice.isAdded(window(7, title: "Budget"), to: records))
        #expect(
            !WindowChoice.isAdded(
                window(7, bundle: "com.apple.finder", application: "Finder", title: "Launch Deck"), to: records))
        #expect(!WindowChoice.isAdded(window(7, title: "Launch Deck"), to: []))
    }

    @Test("windows group under their application in first-appearance order, each group keeping its order")
    func groups() {
        let groups = WindowChoice.groups(from: [
            window(2, bundle: "com.apple.finder", application: "Finder", title: "Downloads"),
            window(3, title: "Budget"),
            window(1, title: "Roadmap"),
            window(4, bundle: "com.apple.Safari", application: "Safari", title: "Apple"),
        ])
        #expect(groups.map(\.applicationName) == ["Finder", "Keynote", "Safari"])
        #expect(groups.map(\.id) == ["com.apple.finder", "com.apple.Keynote", "com.apple.Safari"])
        #expect(groups.map { $0.windows.map(\.id) } == [[2], [3, 1], [4]])
    }

    @Test("two applications sharing a name stay two groups")
    func groupsByBundleIdentifier() {
        let groups = WindowChoice.groups(from: [
            window(1, bundle: "com.example.one", application: "Notes", title: "A"),
            window(2, bundle: "com.example.two", application: "Notes", title: "B"),
        ])
        #expect(groups.count == 2)
    }

    @Test("no windows make no groups")
    func groupsOfNothing() {
        #expect(WindowChoice.groups(from: []).isEmpty)
    }

    @Test("groups compare equal when matching and unequal when their windows differ")
    func groupEquality() {
        let one = WindowChoice.groups(from: [window(1, title: "A")])
        #expect(one == WindowChoice.groups(from: [window(1, title: "A")]))
        #expect(one != WindowChoice.groups(from: [window(2, title: "A")]))
    }

    @Test("a window's size reads in whole points with no grouping separator")
    func sizeText() {
        #expect(WindowChoice.sizeText(for: window(1, title: "A", width: 1512.4, height: 948.6)) == "1512 × 949")
    }
}
