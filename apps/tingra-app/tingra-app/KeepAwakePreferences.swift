//
//  KeepAwakePreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the operator's Keep Mac Awake choice lives: **machine-local
/// preferences**, on the ``StatusBarPreferences`` pattern.
///
/// The project document would be wrong for the usual reason — whether this
/// Mac may idle to sleep under a session is a fact about the Mac and its
/// operator, not about the show, and a project carried to another machine
/// would carry one desk's power habits to another's.
struct KeepAwakePreferences {
    /// The defaults database the value lives in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The keep-awake key.
    private static let enabledKey = "keepAwake.enabled"

    /// What a fresh install does: keeps the Mac awake.
    ///
    /// On rather than off because a system sleep pauses a live stream or a
    /// recording for its whole length (CLOCK.md, "System sleep and App
    /// Nap"), and an operator who has never opened Settings should not learn
    /// that on air. The setting exists for the operator who wants the Mac's
    /// own power settings to win.
    static let defaultIsEnabled = true

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a session holds the Mac awake.
    ///
    /// A missing value reads ``defaultIsEnabled`` rather than `false`, which
    /// `UserDefaults.bool` alone could not express, so the presence of the
    /// key is checked first (the ``StatusBarPreferences/isVisible`` rule).
    var isEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.enabledKey) != nil else { return Self.defaultIsEnabled }
            return defaults.bool(forKey: Self.enabledKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}
