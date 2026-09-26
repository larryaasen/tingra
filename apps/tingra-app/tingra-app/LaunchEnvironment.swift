//
//  LaunchEnvironment.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-25.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// What the process was launched to do, as its environment says.
///
/// The app's unit tests run inside Tingra.app — an app target's tests need a
/// host — so every test run launches the real app on the developer's own
/// Mac. Booting the engine there would start the developer's cameras and
/// displays, load and autosave their real project, record their session
/// position, and append to their real log, none of which any test uses: the
/// tests build their own ``EngineModel`` over test doubles and never call
/// ``EngineModel/start()``. The scheme's Test action sets
/// ``testHostVariable``, and the app skips the boot when it is set.
///
/// An explicit variable of Tingra's own rather than one of the test runner's
/// internal ones, so the rule rests on nothing Apple could rename, and
/// `LaunchEnvironmentTests` proves the scheme still sets it.
enum LaunchEnvironment {
    /// The environment variable the `tingra-app` scheme's Test action sets
    /// to `1` in the test host.
    static let testHostVariable = "TINGRA_TEST_HOST"

    /// Whether this process is the unit tests' host, which must not boot
    /// the engine.
    static var isTestHost: Bool {
        isTestHost(ProcessInfo.processInfo.environment)
    }

    /// Whether an environment marks its process as the unit tests' host.
    ///
    /// - Parameter environment: The process environment to read.
    /// - Returns: True only when ``testHostVariable`` is exactly `1`.
    static func isTestHost(_ environment: [String: String]) -> Bool {
        environment[testHostVariable] == "1"
    }
}
