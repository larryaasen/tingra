//
//  PlugInListingTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-30.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraHost
import TingraPlugInKit

@testable import TingraApp

/// Exercises the Plug-ins pane's rows: one per plug-in across both tiers,
/// each in its section with the standing its report entry gives it.
@Suite("PlugInListing")
struct PlugInListingTests {
    /// A compiled-in entry.
    private func compiledIn(_ id: String, name: String) -> PlugInLoadReport.Entry {
        PlugInLoadReport.Entry(
            id: id, name: name, version: nil, source: .compiledIn, path: nil, state: .active, reason: nil,
            message: nil, warnings: [])
    }

    /// A bundle entry.
    private func bundle(
        _ id: String?, name: String = "Fixture", version: String? = "1.0",
        path: String = "~/Library/Application Support/Tingra/Plug-ins/Fixture.tingraplugin",
        state: PlugInLoadReport.Entry.State = .active, reason: String? = nil, message: String? = nil,
        warnings: [String] = []
    ) -> PlugInLoadReport.Entry {
        PlugInLoadReport.Entry(
            id: id, name: name, version: version, source: .bundle, path: path, state: state, reason: reason,
            message: message, warnings: warnings)
    }

    /// A report over entries.
    private func report(_ entries: [PlugInLoadReport.Entry], safeMode: Bool = false) -> PlugInLoadReport {
        PlugInLoadReport(kitVersion: "0.1.0", safeMode: safeMode, folders: [], plugIns: entries)
    }

    @Test("compiled-in plug-ins are built in, with no bundle standing")
    func compiledInIsBuiltIn() throws {
        let listing = PlugInListing(
            report: report([compiledIn("com.moonwink.tingra.generator", name: "Generators")]), appTier: [])
        let row = try #require(listing.rows.first)
        #expect(listing.builtIn == [row])
        #expect(listing.installed.isEmpty)
        #expect(row.id == "com.moonwink.tingra.generator")
        #expect(row.bundle == nil)
        #expect(row.version == nil)
        #expect(!row.hasWarning)
    }

    @Test("an active bundle is installed and switchable, found on")
    func activeBundle() throws {
        let listing = PlugInListing(report: report([bundle("com.example.fixture")]), appTier: [])
        let row = try #require(listing.installed.first)
        #expect(row.bundle == .switchable(wasOn: true))
        #expect(row.version == "1.0")
        #expect(row.plugInID == PlugInID(rawValue: "com.example.fixture"))
        #expect(!row.hasWarning)
    }

    @Test("a bundle turned off or crashed was found off; one kept out by safe mode was found on")
    func skippedStandings() {
        let listing = PlugInListing(
            report: report([
                bundle("a", path: "~/a.tingraplugin", state: .skipped, reason: "disabled"),
                bundle("b", path: "~/b.tingraplugin", state: .skipped, reason: "crashed"),
                bundle("c", path: "~/c.tingraplugin", state: .skipped, reason: "safeMode"),
            ]), appTier: [])
        #expect(
            listing.rows.map(\.bundle) == [
                .switchable(wasOn: false), .switchable(wasOn: false), .switchable(wasOn: true),
            ])
    }

    @Test("a bundle skipped because plug-ins.json was unreadable has no toggle and carries the message")
    func unreadableStanding() throws {
        let listing = PlugInListing(
            report: report([bundle("a", state: .skipped, reason: "enablementUnreadable", message: "Repair it")]),
            appTier: [])
        let row = try #require(listing.rows.first)
        #expect(row.bundle == .undetermined(message: "Repair it"))
        #expect(row.hasWarning)
    }

    @Test("a refused bundle carries its message and its expanded location, with a warning")
    func refusedBundle() throws {
        let listing = PlugInListing(
            report: report([
                bundle(
                    "com.example.fixture", path: "~/Plug-ins/Unsigned.tingraplugin", state: .refused,
                    reason: "unsigned", message: "It is not signed.")
            ]), appTier: [])
        let row = try #require(listing.installed.first)
        let expected = URL.homeDirectory.appending(path: "Plug-ins/Unsigned.tingraplugin").path(percentEncoded: false)
        guard case .refused(let message, let url) = row.bundle else {
            Issue.record("expected a refusal, got \(String(describing: row.bundle))")
            return
        }
        #expect(message == "It is not signed.")
        #expect(url.path(percentEncoded: false).trimmingCharacters(in: ["/"]) == expected.trimmingCharacters(in: ["/"]))
        #expect(row.hasWarning)
    }

    @Test("a bundle whose activate threw stays switchable and carries the error, with a warning")
    func failedBundle() throws {
        let listing = PlugInListing(
            report: report([bundle("a", state: .failed, message: "activate threw")]), appTier: [])
        let row = try #require(listing.rows.first)
        #expect(row.bundle == .switchable(wasOn: true))
        #expect(row.activationError == "activate threw")
        #expect(row.hasWarning)
    }

    @Test("an active bundle's warnings ride on its row")
    func warningsRide() throws {
        let listing = PlugInListing(report: report([bundle("a", warnings: ["embeds the kit"])]), appTier: [])
        let row = try #require(listing.rows.first)
        #expect(row.warnings == ["embeds the kit"])
        #expect(row.activationError == nil)
        #expect(row.hasWarning)
    }

    @Test("a plug-in with both halves is one installed row carrying the app-tier half")
    func bothHalvesMerge() throws {
        let listing = PlugInListing(
            report: report([bundle("com.example.both", version: nil)]),
            appTier: [.init(id: PlugInID(rawValue: "com.example.both"), name: "Both", version: "2.0", isBuiltIn: false)]
        )
        #expect(listing.rows.count == 1)
        let row = try #require(listing.rows.first)
        #expect(row.section == .installed)
        #expect(row.hasAppTierHalf)
        #expect(row.version == "2.0")
        #expect(row.bundle == .switchable(wasOn: true))
    }

    @Test("an app-tier plug-in with no bundle is built in when embedded and installed otherwise")
    func appTierOnly() {
        let listing = PlugInListing(
            report: report([]),
            appTier: [
                .init(
                    id: PlugInID(rawValue: "com.moonwink.tingra.notes"), name: "Notes", version: "1.0", isBuiltIn: true),
                .init(id: PlugInID(rawValue: "com.example.pane"), name: "Pane", version: nil, isBuiltIn: false),
            ])
        #expect(listing.builtIn.map(\.id) == ["com.moonwink.tingra.notes"])
        #expect(listing.installed.map(\.id) == ["com.example.pane"])
        #expect(listing.rows.allSatisfy { $0.bundle == nil && $0.hasAppTierHalf })
    }

    @Test("with no report yet, only the app tier is listed")
    func noReport() {
        let listing = PlugInListing(
            report: nil,
            appTier: [
                .init(id: PlugInID(rawValue: "com.moonwink.tingra.notes"), name: "Notes", version: nil, isBuiltIn: true)
            ])
        #expect(listing.rows.map(\.name) == ["Notes"])
    }

    @Test("a second bundle declaring a listed id is its own row, keyed by its path, and takes no app-tier half")
    func duplicateIDs() {
        let listing = PlugInListing(
            report: report([
                bundle("com.example.fixture", path: "~/one.tingraplugin"),
                bundle(
                    "com.example.fixture", path: "/Library/two.tingraplugin", state: .refused, reason: "duplicateID",
                    message: "Already loaded."),
            ]),
            appTier: [
                .init(id: PlugInID(rawValue: "com.example.fixture"), name: "Fixture", version: nil, isBuiltIn: false)
            ])
        #expect(listing.rows.map(\.id) == ["com.example.fixture", "path:/Library/two.tingraplugin"])
        #expect(listing.rows.map(\.hasAppTierHalf) == [true, false])
        #expect(Set(listing.rows.map(\.id)).count == listing.rows.count)
    }

    @Test("a bundle declaring no id is keyed by its path")
    func idlessBundle() throws {
        let listing = PlugInListing(
            report: report([bundle(nil, path: "~/x.tingraplugin", state: .refused, reason: "idMismatch", message: "m")]
            ),
            appTier: [])
        let row = try #require(listing.rows.first)
        #expect(row.id == "path:~/x.tingraplugin")
        #expect(row.plugInID == nil)
    }
}
