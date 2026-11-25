//
//  CompactWindowPreferences.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-11-25.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Whether the compact window's controls are collapsed, and the height it
/// returns to when they expand: **machine-local preferences**, like the
/// sidebar sections' expansion (``SidebarPreferences``).
///
/// In `UserDefaults` rather than `@SceneStorage`, because scene storage comes
/// back only with a window macOS restores, and the app quits with its last
/// window closed, so a relaunch opens a new window. The last choice made in
/// any compact window is what the next one opens with.
struct CompactWindowPreferences {
    /// The defaults database the values live in (injectable, so a test runs
    /// against its own suite rather than the user's).
    private let defaults: UserDefaults

    /// The controls' expansion key.
    private static let controlsExpandedKey = "compact.controls.expanded"

    /// The expanded height key.
    private static let expandedHeightKey = "compact.controls.expandedHeight"

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the controls show under their heading. Nothing stored reads
    /// open, so a fresh install shows the controls and collapsing them is the
    /// operator's choice; `UserDefaults.bool` alone returns `false` for a
    /// missing key, so the key's presence is checked first.
    var isControlsExpanded: Bool {
        get {
            guard defaults.object(forKey: Self.controlsExpandedKey) != nil else { return true }
            return defaults.bool(forKey: Self.controlsExpandedKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.controlsExpandedKey) }
    }

    /// The window's height when its controls were last collapsed, which
    /// expanding them restores; nil until they have been.
    var expandedHeight: Double? {
        get {
            let height = defaults.double(forKey: Self.expandedHeightKey)
            return height > 0 ? height : nil
        }
        nonmutating set { defaults.set(newValue, forKey: Self.expandedHeightKey) }
    }
}
