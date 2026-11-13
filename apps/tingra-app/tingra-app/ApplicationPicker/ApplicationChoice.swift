//
//  ApplicationChoice.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraCapturePlugIns
import TingraComposition

/// The pure rules between the two shapes an application takes in the app:
/// the application the picker lists (`CaptureApplication`) and the record the
/// project saves (`ProjectApplication`) — kept out of the model and the sheet
/// so they are unit-tested without either (ARCHITECTURE.md, "Application
/// audio").
nonisolated enum ApplicationChoice {
    /// The project record for an application the operator picked, with a
    /// fresh identity.
    ///
    /// - Parameter application: The picked application.
    /// - Returns: The record.
    static func record(for application: CaptureApplication) -> ProjectApplication {
        ProjectApplication(bundleIdentifier: application.bundleIdentifier, name: application.name)
    }

    /// The application the capture looks for, from a project record.
    ///
    /// - Parameter record: The record.
    /// - Returns: The application.
    static func application(of record: ProjectApplication) -> CaptureApplication {
        CaptureApplication(bundleIdentifier: record.bundleIdentifier, name: record.name)
    }

    /// Whether a project already holds a record for an application: the same
    /// bundle identifier. One application is one input — a second would tap
    /// the same processes twice.
    ///
    /// - Parameters:
    ///   - application: An application the picker lists.
    ///   - records: The project's application records.
    /// - Returns: Whether a record names the application.
    static func isAdded(_ application: CaptureApplication, to records: [ProjectApplication]) -> Bool {
        records.contains { $0.bundleIdentifier == application.bundleIdentifier }
    }
}
