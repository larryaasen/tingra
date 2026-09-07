//
//  SwitcherRowsPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the operator's choice to show the main window's **switcher rows** —
/// the Program and Preview rows of shot buttons beneath the monitoring
/// section — lives: **machine-local preferences**, on the
/// ``StatusBarPreferences`` / ``SidebarPreferences`` pattern.
///
/// The rows are optional because they repeat what the window already shows
/// elsewhere: the sidebar lists every authored shot, the input rows under the
/// monitors are the automatic shots, and the Shots menu stages by number. An
/// operator who works from those has no use for two more rows of the same
/// names, and one who prefers a horizontal bank of shot buttons — the hardware
/// panel's shape — turns them on once and keeps them. Whether they are shown
/// is not part of the show, so the project document is the wrong place, and
/// it must survive a relaunch, so session state is too.
struct SwitcherRowsPreferences {
    /// The defaults database the value lives in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The switcher rows' visibility key.
    private static let visibilityKey = "switcherRows.visible"

    /// What a fresh install shows: no rows.
    ///
    /// Hidden rather than shown because the rows are the one surface in the
    /// window that adds no information — every shot they list is listed in
    /// the sidebar beside them — so a fresh window is shorter without them
    /// and loses nothing.
    static let defaultIsVisible = false

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the switcher rows are shown.
    ///
    /// The presence of the key is checked first, the ``StatusBarPreferences``
    /// rule: a missing value reads ``defaultIsVisible`` rather than whatever
    /// `UserDefaults.bool` returns for a missing key, so the default is stated
    /// in one place and can change without a migration.
    var isVisible: Bool {
        get {
            guard defaults.object(forKey: Self.visibilityKey) != nil else { return Self.defaultIsVisible }
            return defaults.bool(forKey: Self.visibilityKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.visibilityKey) }
    }
}
