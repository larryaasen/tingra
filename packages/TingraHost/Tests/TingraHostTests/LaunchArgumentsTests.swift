//
//  LaunchArgumentsTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

/// Exercises the command-line rule behind `Tingra --version` and
/// `Tingra Cameras --version`, the check a release runs on the signed app
/// before notarizing it.
@Suite("LaunchArguments")
struct LaunchArgumentsTests {
    @Test("--version after the executable asks for the version")
    func flagAsksForVersion() {
        #expect(LaunchArguments.asksForVersion(["/Applications/Tingra.app/Contents/MacOS/Tingra", "--version"]))
    }

    @Test("--version after an executable path with a space asks for the version")
    func flagAfterAPathWithASpace() {
        #expect(
            LaunchArguments.asksForVersion([
                "/Applications/Tingra Cameras.app/Contents/MacOS/Tingra Cameras", "--version",
            ]))
    }

    @Test("--version among other arguments still asks for the version")
    func flagAmongOtherArguments() {
        #expect(LaunchArguments.asksForVersion(["Tingra", "-NSDocumentRevisionsDebugMode", "YES", "--version"]))
    }

    @Test("a launch with no arguments does not ask for the version")
    func noArguments() {
        #expect(!LaunchArguments.asksForVersion(["Tingra"]))
        #expect(!LaunchArguments.asksForVersion([]))
    }

    @Test("an executable path that happens to be the flag is not a request")
    func executableIsNeverTheFlag() {
        #expect(!LaunchArguments.asksForVersion(["--version"]))
    }

    @Test("near misses do not ask for the version")
    func nearMisses() {
        #expect(!LaunchArguments.asksForVersion(["Tingra", "-version"]))
        #expect(!LaunchArguments.asksForVersion(["Tingra", "--versions"]))
        #expect(!LaunchArguments.asksForVersion(["Tingra", "version"]))
    }

    @Test("the version line is the marketing version alone")
    func versionLineIsTheShortVersion() {
        #expect(LaunchArguments.versionLine(for: AppVersion(shortVersion: "0.2.0", build: "0.2.0")) == "0.2.0")
        #expect(LaunchArguments.versionLine(for: AppVersion(shortVersion: "0.2.0", build: "17")) == "0.2.0")
    }

    @Test("a bundle that names no version has no version line")
    func noVersionNoLine() {
        #expect(LaunchArguments.versionLine(for: AppVersion(shortVersion: nil, build: "17")) == nil)
    }
}
