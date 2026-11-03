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
import TingraHost

@testable import TingraApp

/// Exercises the version the built app carries. `AppVersion` and the
/// `--version` rule are tested in TingraHost; what only the app's own bundle
/// can show is tested here.
@Suite("AppVersion in the app bundle")
struct AppVersionTests {
    @Test("the app's own bundle names a version")
    func theAppBundleNamesAVersion() {
        // The About pane exists to print this; a bundle that stopped carrying
        // it would be a build-configuration defect the pane would only report
        // as "Version unavailable" at runtime.
        #expect(AppVersion(bundle: .main).displayString != nil)
    }

    @Test("the app and the CLI carry one product version")
    func appVersionMatchesTheProductVersion() throws {
        // The test bundle sits in the app's PlugIns folder, so the app's own
        // bundle is the main bundle here.
        let appVersion = try #require(AppVersion().shortVersion)
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let versionFile = repository.appending(path: "apps/tingra-cli/Sources/TingraCLI/Version.swift")
        let contents = try String(contentsOf: versionFile, encoding: .utf8)
        #expect(contents.contains("static let current = \"\(appVersion)\""))
    }
}
