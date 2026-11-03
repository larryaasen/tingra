//
//  AppVersionTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

/// Exercises the version text both apps' About panes print, and reading it
/// from a bundle.
@Suite("AppVersion")
struct AppVersionTests {
    @Test("a version with a build prints the build in parentheses after it")
    func versionAndBuildPrintTogether() {
        #expect(AppVersion(shortVersion: "1.0", build: "42").displayString == "1.0 (42)")
    }

    @Test("a build that repeats the version is not printed twice")
    func aRepeatedBuildIsDropped() {
        #expect(AppVersion(shortVersion: "1.0", build: "1.0").displayString == "1.0")
    }

    @Test("a version with no build prints the version alone")
    func versionAlonePrintsAlone() {
        #expect(AppVersion(shortVersion: "2.1", build: nil).displayString == "2.1")
    }

    @Test("a build with no version is better than nothing, so it is what prints")
    func buildAlonePrintsAlone() {
        #expect(AppVersion(shortVersion: nil, build: "409").displayString == "409")
    }

    @Test("a bundle naming no version at all returns nothing rather than inventing one")
    func noVersionReturnsNothing() {
        #expect(AppVersion(shortVersion: nil, build: nil).displayString == nil)
    }

    @Test("two versions with the same parts are equal")
    func equalVersionsMatch() {
        #expect(AppVersion(shortVersion: "1.0", build: "1") == AppVersion(shortVersion: "1.0", build: "1"))
    }

    @Test("versions differing in either part are not equal")
    func differingVersionsDoNotMatch() {
        #expect(AppVersion(shortVersion: "1.0", build: "1") != AppVersion(shortVersion: "1.1", build: "1"))
        #expect(AppVersion(shortVersion: "1.0", build: "1") != AppVersion(shortVersion: "1.0", build: "2"))
        #expect(AppVersion(shortVersion: "1.0", build: "1") != AppVersion(shortVersion: nil, build: "1"))
    }

    @Test("a bundle's two version keys are read into the two parts")
    func readsBothKeysFromABundle() throws {
        let bundle = try Self.bundle(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"])
        #expect(AppVersion(bundle: bundle) == AppVersion(shortVersion: "0.1.0", build: "7"))
    }

    @Test("a bundle missing its version keys reads as no version")
    func readsMissingKeysAsNil() throws {
        let bundle = try Self.bundle(info: ["CFBundleIdentifier": "com.moonwink.tingra.tests.no-version"])
        #expect(AppVersion(bundle: bundle) == AppVersion(shortVersion: nil, build: nil))
    }

    /// Writes a bundle holding only an Info.plist, in a folder of its own, and
    /// opens it.
    ///
    /// - Parameter info: The Info.plist's keys.
    /// - Returns: The bundle.
    /// - Throws: An error when the folder or the property list cannot be
    ///   written, or the folder does not open as a bundle.
    private static func bundle(info: [String: String]) throws -> Bundle {
        let folder = URL.temporaryDirectory.appending(path: "AppVersionTests-\(UUID().uuidString).bundle")
        let contents = folder.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        return try #require(Bundle(url: folder))
    }
}
