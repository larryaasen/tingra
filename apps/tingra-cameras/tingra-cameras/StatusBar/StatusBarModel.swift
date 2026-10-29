//
//  StatusBarModel.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation

/// Where the operator's Show Status Bar choice lives: **machine-local
/// preferences**, the main Tingra app's pattern. Every macOS status bar an
/// operator has met (the Finder's, Preview's) remembers its state, so one
/// that came back each launch would read as a bug.
struct StatusBarPreferences {
    /// The defaults database the value lives in (injectable, so a test runs
    /// against its own suite rather than the user's).
    private let defaults: UserDefaults

    /// The status bar visibility key.
    private static let visibilityKey = "statusBar.visible"

    /// What a fresh install shows: the bar, so the selected camera's state
    /// and resolution are readable before anyone opens Settings.
    static let defaultIsVisible = true

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the status bar is shown. A missing value reads
    /// ``defaultIsVisible`` rather than the `false` `UserDefaults.bool`
    /// returns for a missing key.
    var isVisible: Bool {
        get {
            guard defaults.object(forKey: Self.visibilityKey) != nil else { return Self.defaultIsVisible }
            return defaults.bool(forKey: Self.visibilityKey)
        }
        nonmutating set { defaults.set(newValue, forKey: Self.visibilityKey) }
    }
}

/// Whether the windows carry a status bar, as the General settings pane and
/// the View menu edit it: the stored choice plus the observation that makes a
/// change made in one window reach every other one.
///
/// A shared observable rather than each window reading `UserDefaults` for
/// itself, because the setting is edited in a different window (Settings)
/// and `UserDefaults` is not observable.
@MainActor
@Observable
final class StatusBarModel {
    /// Where the choice persists.
    @ObservationIgnored private let preferences: StatusBarPreferences

    /// Whether the status bar is shown. Writing it persists the choice, so a
    /// stored value and a drawn window can never disagree.
    var isVisible: Bool {
        didSet {
            guard isVisible != oldValue else { return }
            preferences.isVisible = isVisible
        }
    }

    /// Creates the model from the stored choice.
    ///
    /// - Parameter preferences: Where the choice persists.
    init(preferences: StatusBarPreferences) {
        self.preferences = preferences
        self.isVisible = preferences.isVisible
    }

    /// Creates the model over the standard defaults. A convenience
    /// initializer rather than a default argument, because a default
    /// argument is evaluated outside the main actor and the preferences are
    /// a main-actor value in this target.
    convenience init() {
        self.init(preferences: StatusBarPreferences())
    }
}
