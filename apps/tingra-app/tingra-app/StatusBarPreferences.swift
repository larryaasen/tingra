//
//  StatusBarPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the operator's Show Status Bar choice lives: **machine-local
/// preferences**, on the ``AppearancePreferences`` / ``SidebarPreferences``
/// pattern.
///
/// The project document would be wrong for the reason it is wrong for the
/// appearance and the sidebar's folded sections — whether an operator wants a
/// bar across the bottom of their windows is not part of the show, and a
/// project carried to another Mac would carry one operator's window habits to
/// another's. Session-only would be wrong too: every macOS status bar an
/// operator has met (the Finder's, Preview's) remembers its state, so one that
/// came back each launch would read as a bug.
struct StatusBarPreferences {
    /// The defaults database the value lives in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The status bar visibility key.
    private static let visibilityKey = "statusBar.visible"

    /// What a fresh install shows: the bar.
    ///
    /// Shown rather than hidden because the bar answers the two questions this
    /// app exists to keep answered — am I on air, am I recording — and an
    /// operator who has never opened Settings should have those answers.
    static let defaultIsVisible = true

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the status bar is shown.
    ///
    /// A missing value reads ``defaultIsVisible`` rather than `false`, which
    /// `UserDefaults.bool` alone could not express — it returns `false` for a
    /// missing key — so the presence of the key is what is checked first (the
    /// ``SidebarPreferences/isExpanded(_:)`` rule).
    var isVisible: Bool {
        get {
            guard defaults.object(forKey: Self.visibilityKey) != nil else { return Self.defaultIsVisible }
            return defaults.bool(forKey: Self.visibilityKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.visibilityKey) }
    }
}
