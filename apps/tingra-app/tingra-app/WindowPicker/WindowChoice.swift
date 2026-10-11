//
//  WindowChoice.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraCapturePlugIns
import TingraComposition

/// The pure rules between the three shapes a window takes in the app: the
/// window the picker lists (`CaptureWindow`), the record the project saves
/// (`ProjectWindow`), and the description the capture looks for
/// (`WindowTarget`) — kept out of the model and the sheet so they are
/// unit-tested without either (ARCHITECTURE.md, "Window capture").
nonisolated enum WindowChoice {
    /// One application's windows in the picker, under its name.
    struct Group: Identifiable, Equatable {
        /// The application's bundle identifier.
        let id: String

        /// The application's user-facing name, the group's heading.
        let applicationName: String

        /// The application's windows, in the picker's order.
        let windows: [CaptureWindow]
    }

    /// The project record for a window the operator picked, with a fresh
    /// identity.
    ///
    /// - Parameter window: The picked window.
    /// - Returns: The record.
    static func record(for window: CaptureWindow) -> ProjectWindow {
        ProjectWindow(
            bundleIdentifier: window.target.bundleIdentifier,
            applicationName: window.target.applicationName,
            title: window.target.title
        )
    }

    /// The description the capture looks for, from a project record.
    ///
    /// - Parameter record: The record.
    /// - Returns: The target.
    static func target(of record: ProjectWindow) -> WindowTarget {
        WindowTarget(
            bundleIdentifier: record.bundleIdentifier,
            applicationName: record.applicationName,
            title: record.title
        )
    }

    /// Whether a project already holds a record for a window: the same
    /// application and the same title. Two windows an application gives one
    /// title are one record — the capture could not tell them apart on the
    /// next launch either.
    ///
    /// - Parameters:
    ///   - window: A window the picker lists.
    ///   - records: The project's window records.
    /// - Returns: Whether a record describes the window.
    static func isAdded(_ window: CaptureWindow, to records: [ProjectWindow]) -> Bool {
        records.contains { target(of: $0) == window.target }
    }

    /// The picker's windows grouped by application, keeping the order they
    /// arrive in — by application and then title — so each application's
    /// windows sit together under its name.
    ///
    /// Grouped by bundle identifier rather than by name: two applications
    /// can share a name, and their windows are not one list.
    ///
    /// - Parameter windows: The windows, in the picker's order.
    /// - Returns: The groups, in first-appearance order.
    static func groups(from windows: [CaptureWindow]) -> [Group] {
        var order: [String] = []
        var byApplication: [String: [CaptureWindow]] = [:]
        for window in windows {
            let key = window.target.bundleIdentifier
            if byApplication[key] == nil { order.append(key) }
            byApplication[key, default: []].append(window)
        }
        return order.compactMap { key in
            guard let windows = byApplication[key], let first = windows.first else { return nil }
            return Group(id: key, applicationName: first.target.applicationName, windows: windows)
        }
    }

    /// A window's size as the picker shows it, in whole points:
    /// "1280 × 720".
    ///
    /// - Parameter window: The window.
    /// - Returns: The size text.
    static func sizeText(for window: CaptureWindow) -> String {
        let style = IntegerFormatStyle<Int>.number.grouping(.never)
        return "\(Int(window.width.rounded()).formatted(style)) × \(Int(window.height.rounded()).formatted(style))"
    }
}
