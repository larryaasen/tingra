//
//  AppearancePreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation

/// Which appearance the app draws in — the General settings tab's Appearance
/// control, and the one setting that changes every window at once.
///
/// Three cases rather than a boolean, because "follow the system" is a
/// **distinct state** and not the absence of a choice: an operator on System
/// gets the automatic light-to-dark switch at sunset, where one on Light stays
/// light through it. A boolean could not tell those apart.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system setting, including its automatic switch — the
    /// default, and what an app should do until the operator says otherwise.
    case system

    /// Always light, whatever the system is set to.
    case light

    /// Always dark, whatever the system is set to.
    case dark

    /// The mode's own raw value, so the picker can identify it.
    var id: String { rawValue }

    /// The AppKit appearance to install on the application, or nil for
    /// ``system`` — which is not "no appearance" but *inherit*: an app whose
    /// `appearance` is nil takes the system's, and keeps taking it as the
    /// system changes.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Where the operator's appearance choice lives: **machine-local
/// preferences**, on the ``MonitorPreferences`` / ``SidebarPreferences``
/// pattern.
///
/// The project document would be wrong for the same reason it is wrong for the
/// monitor device and the sidebar's folded sections — how an operator likes
/// their windows to look is not part of the show, and a project carried to
/// another Mac would carry one operator's eyes to another's. Session-only
/// would be wrong too: an appearance that reset every launch is the kind of
/// thing a user files as a bug.
struct AppearancePreferences {
    /// The defaults database the value lives in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The appearance mode key.
    private static let modeKey = "appearance.mode"

    /// What a fresh install draws in: the system's appearance.
    static let defaultMode: AppearanceMode = .system

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The chosen appearance.
    ///
    /// A missing — or unrecognizable — stored value reads ``defaultMode``
    /// rather than trapping or picking light: a defaults database can hold
    /// anything (an older build's spelling, a hand-edited plist), and the
    /// honest response to a value this app does not know is to follow the
    /// system, which is what it would have done with no value at all.
    var mode: AppearanceMode {
        get { defaults.string(forKey: Self.modeKey).flatMap(AppearanceMode.init(rawValue:)) ?? Self.defaultMode }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.modeKey) }
    }
}
