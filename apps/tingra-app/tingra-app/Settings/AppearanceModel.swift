//
//  AppearanceModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Observation

/// The one thing ``AppearanceModel`` needs of the application: somewhere to
/// install an appearance.
///
/// A protocol seam rather than a direct `NSApplication` reference, the same
/// rule every framework boundary in this repo follows (CLAUDE.md, "Dependency
/// Injection Pattern"). It earns its keep immediately: a test can watch what
/// the model installs without repainting the test host — and repainting a
/// shared `NSApplication` from suites that run in parallel is exactly the
/// kind of global mutation that makes a test flaky.
@MainActor
protocol AppearanceTarget: AnyObject {
    /// The appearance to draw in, or nil to inherit the system's.
    var appearance: NSAppearance? { get set }
}

/// The real target: the running application.
extension NSApplication: AppearanceTarget {}

/// The app's appearance, as the General settings tab edits it: the stored
/// ``AppearanceMode`` plus the one side effect that makes the setting real —
/// installing the matching `NSAppearance` on the running application.
///
/// Its own small `@Observable` beside ``EngineModel`` rather than a property
/// on it, because the two have nothing to do with each other: the engine is
/// the show, and this is how the operator's windows are painted. Keeping it
/// separate is also what lets the setting apply before the engine has started
/// — the appearance is installed at launch, not after the first frame.
///
/// The application-wide install is deliberately not per-window: an app whose
/// settings window went dark while its production window stayed light would
/// be showing the operator two different apps.
@MainActor
@Observable
final class AppearanceModel {
    /// Where the choice persists.
    @ObservationIgnored private let preferences: AppearancePreferences

    /// The application the appearance is installed on. Injected so a test can
    /// exercise the install against its own target rather than the running
    /// app (see ``AppearanceTarget``).
    @ObservationIgnored private let application: any AppearanceTarget

    /// The chosen appearance. Writing it persists the choice and repaints
    /// every window — the two things "changing the appearance" has to mean,
    /// done together so a stored value and a painted window can never
    /// disagree.
    var mode: AppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            preferences.mode = mode
            apply()
        }
    }

    /// Creates the model from the stored choice and installs it immediately,
    /// so the first window drawn is already in the operator's appearance
    /// rather than flashing the system's and correcting itself.
    ///
    /// - Parameters:
    ///   - preferences: Where the choice persists (the standard defaults by
    ///     default).
    ///   - application: The application to paint (the running one by
    ///     default).
    init(
        preferences: AppearancePreferences = AppearancePreferences(),
        application: any AppearanceTarget = NSApplication.shared
    ) {
        self.preferences = preferences
        self.application = application
        self.mode = preferences.mode
        apply()
    }

    /// Installs the current mode's appearance on the application.
    ///
    /// Nil for ``AppearanceMode/system`` is the *inherit* value, not an
    /// absent one — see ``AppearanceMode/appearance``.
    private func apply() {
        application.appearance = mode.appearance
    }
}
