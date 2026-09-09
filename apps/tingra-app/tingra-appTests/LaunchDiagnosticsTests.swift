//
//  LaunchDiagnosticsTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus

@testable import TingraApp

@Suite("LaunchDiagnostics")
struct LaunchDiagnosticsTests {
    /// Diagnostics with every reading present.
    private let complete = LaunchDiagnostics(
        version: AppVersion(shortVersion: "1.2", build: "34"),
        systemVersion: "26.6.0",
        systemBuild: "25G123",
        hardwareModel: "Mac15,3"
    )

    @Test("the event is app.launched")
    func eventName() {
        #expect(LaunchDiagnostics.eventName == "app.launched")
    }

    @Test("every present reading becomes a param under its camelCase key")
    func completeParams() {
        #expect(
            complete.params == [
                "appVersion": .string("1.2"),
                "appBuild": .string("34"),
                "systemVersion": .string("26.6.0"),
                "systemBuild": .string("25G123"),
                "hardwareModel": .string("Mac15,3"),
            ])
    }

    @Test("a missing reading drops its key rather than writing a placeholder")
    func missingReadingsDropKeys() {
        let sparse = LaunchDiagnostics(
            version: AppVersion(shortVersion: nil, build: nil),
            systemVersion: "26.6.0",
            systemBuild: nil,
            hardwareModel: nil
        )
        #expect(sparse.params == ["systemVersion": .string("26.6.0")])
    }

    @Test("the running process reads a dotted macOS version and a Mac model identifier")
    func readsTheRunningProcess() throws {
        let diagnostics = LaunchDiagnostics()
        #expect(diagnostics.systemVersion.split(separator: ".").count == 3)
        // The identifier is a family name and two numbers, like `Mac15,3`.
        let model = try #require(diagnostics.hardwareModel)
        #expect(model.wholeMatch(of: /[A-Za-z]+\d+,\d+/) != nil)
        #expect(diagnostics.systemBuild?.isEmpty == false)
    }

    @Test("an unknown sysctl key reads nil")
    func unknownSysctlKey() {
        #expect(LaunchDiagnostics.sysctlString("tingra.no.such.key") == nil)
    }

    @Test("diagnostics compare equal when every reading matches and unequal when one differs")
    func equality() {
        let same = LaunchDiagnostics(
            version: AppVersion(shortVersion: "1.2", build: "34"),
            systemVersion: "26.6.0",
            systemBuild: "25G123",
            hardwareModel: "Mac15,3"
        )
        #expect(complete == same)
        let other = LaunchDiagnostics(
            version: AppVersion(shortVersion: "1.2", build: "34"),
            systemVersion: "26.6.0",
            systemBuild: "25G123",
            hardwareModel: "Mac16,1"
        )
        #expect(complete != other)
    }
}
