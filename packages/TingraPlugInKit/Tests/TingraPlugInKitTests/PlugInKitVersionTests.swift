//
//  PlugInKitVersionTests.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraPlugInKit

@Suite("PlugInKitVersion")
struct PlugInKitVersionTests {
    @Test("a three-part version parses into its numbers")
    func parsesThreeParts() {
        #expect(PlugInKitVersion("1.2.3") == PlugInKitVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("a two-part version parses with a zero patch")
    func parsesTwoParts() {
        #expect(PlugInKitVersion("0.4") == PlugInKitVersion(major: 0, minor: 4, patch: 0))
    }

    @Test(
        "a string that is not two or three dot-separated digit runs is not a version",
        arguments: ["", "1", "1.2.3.4", "a.b.c", "+1.2.3", "-1.0.0", "1..2", " 1.0.0", "1.0.0-beta", "1.٣.0"])
    func rejectsMalformedStrings(_ string: String) {
        #expect(PlugInKitVersion(string) == nil)
    }

    @Test("the description is MAJOR.MINOR.PATCH and parses back to the same version")
    func descriptionRoundTrips() {
        let version = PlugInKitVersion(major: 2, minor: 10, patch: 7)
        #expect(version.description == "2.10.7")
        #expect(PlugInKitVersion(version.description) == version)
    }

    @Test("the current version parses back from its own description")
    func currentRoundTrips() {
        #expect(PlugInKitVersion(PlugInKitVersion.current.description) == .current)
    }

    @Test("versions order by major, then minor, then patch")
    func ordering() {
        #expect(PlugInKitVersion(major: 1, minor: 9, patch: 9) < PlugInKitVersion(major: 2, minor: 0, patch: 0))
        #expect(PlugInKitVersion(major: 1, minor: 2, patch: 9) < PlugInKitVersion(major: 1, minor: 3, patch: 0))
        #expect(PlugInKitVersion(major: 1, minor: 2, patch: 3) < PlugInKitVersion(major: 1, minor: 2, patch: 4))
        #expect(!(PlugInKitVersion(major: 1, minor: 2, patch: 3) < PlugInKitVersion(major: 1, minor: 2, patch: 3)))
    }

    @Test("equal versions compare equal, and differing ones do not")
    func equality() {
        #expect(PlugInKitVersion(major: 1, minor: 2, patch: 3) == PlugInKitVersion(major: 1, minor: 2, patch: 3))
        #expect(PlugInKitVersion(major: 1, minor: 2, patch: 3) != PlugInKitVersion(major: 1, minor: 2, patch: 4))
    }
}
