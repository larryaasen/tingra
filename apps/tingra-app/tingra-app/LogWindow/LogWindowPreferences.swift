//
//  LogWindowPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost

/// Where the log window's lasting filter choices live: **machine-local
/// preferences**, on the ``StatusBarPreferences`` pattern.
///
/// Only the choices that describe how someone reads a log persist — the levels,
/// whether taps show, and which launches: a developer who hides DEBUG hides it
/// every time. The domain and the search do not, because the domains present
/// change with the file and a search is a question about the lines in front of
/// you (ARCHITECTURE.md, "The log window").
struct LogWindowPreferences {
    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The shown levels key: an array of the levels' raw values.
    private static let levelsKey = "logWindow.levels"

    /// The show-taps key.
    private static let showsTapsKey = "logWindow.showsTaps"

    /// The launch scope key.
    private static let launchKey = "logWindow.launch"

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The levels shown. Every level when nothing is stored; a stored value
    /// that names no level is ignored rather than trapping.
    var levels: Set<LogLevel> {
        get {
            guard let stored = defaults.stringArray(forKey: Self.levelsKey) else { return Set(LogLevel.allCases) }
            return Set(stored.compactMap(LogLevel.init(rawValue:)))
        }
        nonmutating set {
            defaults.set(LogLevel.allCases.filter(newValue.contains).map(\.rawValue), forKey: Self.levelsKey)
        }
    }

    /// Whether tap lines are shown; shown when nothing is stored, which
    /// `UserDefaults.bool` alone could not express, so the key's presence is
    /// checked first.
    var showsTaps: Bool {
        get {
            guard defaults.object(forKey: Self.showsTapsKey) != nil else { return true }
            return defaults.bool(forKey: Self.showsTapsKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.showsTapsKey) }
    }

    /// Which launches are shown; every launch when nothing, or nothing
    /// recognizable, is stored.
    var launch: LogLaunchScope {
        get { defaults.string(forKey: Self.launchKey).flatMap(LogLaunchScope.init(rawValue:)) ?? .all }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.launchKey) }
    }
}
