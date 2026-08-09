//
//  StatusBarModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Observation

/// Whether the windows carry a status bar, as the General settings pane edits
/// it: the stored choice plus the observation that makes a toggle in one
/// window reach every other one.
///
/// Its own small `@Observable` beside ``AppearanceModel`` rather than a
/// property on ``EngineModel``, for the same reason the appearance is: how the
/// operator's windows are dressed has nothing to do with the show. Keeping it
/// out of the engine model is also what lets the multiview window read it
/// without reaching further into the engine than a monitoring window should.
///
/// A shared observable rather than each window reading `UserDefaults` for
/// itself, because the setting is edited in a *third* window: `UserDefaults`
/// is not observable, so a checkbox in Settings would leave the main window
/// and the multiview showing yesterday's answer until they were redrawn for
/// some other reason.
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
    /// - Parameter preferences: Where the choice persists (the standard
    ///   defaults by default).
    init(preferences: StatusBarPreferences = StatusBarPreferences()) {
        self.preferences = preferences
        self.isVisible = preferences.isVisible
    }
}
