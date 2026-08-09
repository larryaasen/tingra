//
//  AppVersionTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraApp

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

    @Test("the app's own bundle names a version")
    func theAppBundleNamesAVersion() {
        // The About pane exists to print this; a bundle that stopped carrying
        // it would be a build-configuration defect the pane would only report
        // as "Version unavailable" at runtime.
        #expect(AppVersion(bundle: .main).displayString != nil)
    }
}
