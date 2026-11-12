//
//  PaneRecovery.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// How a plug-in pane comes back after its scene ends with an error: a few
/// tries, each waiting longer than the last, and then a stop the operator
/// can see (PLUGINS.md, "A pane that cannot start").
///
/// Until 2026-11-11 a pane was re-hosted one second after every such ending,
/// without limit. That suits an extension that crashed once. It does not suit
/// one the system refuses to launch at all — a signature it will not accept,
/// a missing entitlement — where every try ends the same way: the pane then
/// asked twice a second for as long as the app ran, behind a placeholder
/// that never changed.
///
/// A value with no clock of its own: it says what to do next, and
/// ``AppPlugInHost`` does the waiting.
nonisolated struct PaneRecovery: Equatable, Sendable {
    /// What to do after a scene ended with an error.
    enum Step: Equatable, Sendable {
        /// Host the scene again after the wait.
        case retry(after: Duration)

        /// Stop trying; the pane shows that it could not start.
        case giveUp
    }

    /// How many endings in a row are met with another try. The one after
    /// gives up.
    static let maximumRetries = 4

    /// The wait before the first retry. Each later one doubles it: 1, 2, 4,
    /// and 8 seconds, fifteen in all before the pane gives up.
    static let firstDelay: Duration = .seconds(1)

    /// How many scenes in a row have ended with an error.
    private(set) var failures = 0

    /// Records a scene ending with an error and says what to do next.
    ///
    /// - Returns: A retry with its wait, or the stop.
    mutating func sceneFailed() -> Step {
        failures += 1
        guard failures <= Self.maximumRetries else { return .giveUp }
        return .retry(after: Self.firstDelay * (1 << (failures - 1)))
    }

    /// Records a scene coming up: the run of errors is over, so the next
    /// one starts the count again.
    mutating func sceneActivated() {
        failures = 0
    }
}
