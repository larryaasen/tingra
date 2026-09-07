//
//  SwitcherRowsModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Observation

/// Whether the main window shows its switcher rows, as the General settings
/// pane edits it: the stored choice plus the observation that lets a checkbox
/// in the settings window reach the main window at once.
///
/// ``StatusBarModel``'s shape exactly, and for its reason: the checkbox lives
/// in a *different* window from the rows it shows and hides, and
/// `UserDefaults` is not observable, so the main window would go on showing
/// yesterday's answer until something else redrew it. Its own small
/// `@Observable` rather than a property on ``EngineModel`` because how the
/// operator's window is arranged has nothing to do with the show.
@MainActor
@Observable
final class SwitcherRowsModel {
    /// Where the choice persists.
    @ObservationIgnored private let preferences: SwitcherRowsPreferences

    /// Whether the switcher rows are shown. Writing it persists the choice,
    /// so a stored value and a drawn window can never disagree.
    var isVisible: Bool {
        didSet {
            guard isVisible != oldValue else { return }
            preferences.isVisible = isVisible
        }
    }

    /// Creates the model from the stored choice.
    ///
    /// - Parameter preferences: Where the choice persists (the standard
    ///   defaults by default).
    init(preferences: SwitcherRowsPreferences = SwitcherRowsPreferences()) {
        self.preferences = preferences
        self.isVisible = preferences.isVisible
    }
}
