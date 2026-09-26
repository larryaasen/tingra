//
//  LaunchEnvironmentTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-25.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApp

/// Exercises the test-host flag that keeps a test run from booting the
/// engine against the developer's own devices and data.
@Suite("LaunchEnvironment")
struct LaunchEnvironmentTests {
    @Test("the scheme marks the process these tests run in as the test host")
    func schemeSetsTheTestHostVariable() {
        #expect(LaunchEnvironment.isTestHost)
    }

    @Test("an environment with the variable set to 1 is the test host")
    func variableSetIsTestHost() {
        #expect(LaunchEnvironment.isTestHost(["TINGRA_TEST_HOST": "1"]))
    }

    @Test("an environment without the variable is not the test host")
    func variableAbsentIsNotTestHost() {
        #expect(!LaunchEnvironment.isTestHost([:]))
        #expect(!LaunchEnvironment.isTestHost(["PATH": "/usr/bin"]))
    }

    @Test("any value other than 1 is not the test host")
    func otherValuesAreNotTestHost() {
        #expect(!LaunchEnvironment.isTestHost(["TINGRA_TEST_HOST": "0"]))
        #expect(!LaunchEnvironment.isTestHost(["TINGRA_TEST_HOST": ""]))
        #expect(!LaunchEnvironment.isTestHost(["TINGRA_TEST_HOST": "yes"]))
    }
}
