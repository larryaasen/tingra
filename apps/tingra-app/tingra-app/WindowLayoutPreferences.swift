//
//  WindowLayoutPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Which of the main window's columns are shown: **machine-local
/// preferences**, following ``SidebarPreferences`` exactly — today, the
/// trailing inspector column (``TrailingSidebar``).
///
/// Persisted since 2026-11-07, reversing the inspector column's record
/// (ARCHITECTURE.md, "The inspector column and the sidebar's casting
/// pickers"), which kept the column session-only as "part of the window's
/// shape, not a preference". Larry, on relaunching: the column he had closed
/// came back. Every macOS app with an inspector the operator has used —
/// Keynote, Xcode — reopens with it as it was left, so a column that
/// reappeared each launch read as a bug, the same reasoning that persists the
/// sidebar's collapsed sections. Not the **document**: whether a column is
/// open is one operator's window habit on one Mac, not part of the show.
struct WindowLayoutPreferences {
    /// The defaults key the inspector column's visibility persists under.
    static let inspectorPresentedKey = "window.inspector.presented"

    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the trailing inspector column is shown.
    ///
    /// Nothing stored reads **shown**, so a fresh install opens with the
    /// column the layer editor works in, and hiding it is something the
    /// operator chooses. `UserDefaults.bool` alone returns `false` for a
    /// missing key, so the key's presence is checked first.
    var isInspectorPresented: Bool {
        guard defaults.object(forKey: Self.inspectorPresentedKey) != nil else { return true }
        return defaults.bool(forKey: Self.inspectorPresentedKey)
    }

    /// Records whether the trailing inspector column is shown.
    ///
    /// - Parameter isPresented: Whether the column is shown.
    func setInspectorPresented(_ isPresented: Bool) {
        defaults.set(isPresented, forKey: Self.inspectorPresentedKey)
    }
}
