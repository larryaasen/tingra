//
//  MonitorPreferences.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the operator's monitor choices live: **machine-local preferences**,
/// not the project document and not session state (ARCHITECTURE.md, "The
/// monitor path").
///
/// The document would be wrong — which headphones are plugged into this Mac
/// is not part of the show, the same test that keeps stream keys, the active
/// shot, and the staged shot out of it, and a project carried to another
/// machine would name a device that does not exist. Session-only would be
/// wrong too, and this is where monitoring differs from a staged shot: an
/// operator's headphones do not change between launches, so re-picking them
/// every launch would be a defect rather than a discipline.
///
/// The device is stored by its stable Core Audio UID, so a device that is
/// absent at launch keeps its selection and simply does not monitor until it
/// returns — the dormant-strip semantic, one path over.
struct MonitorPreferences {
    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The selected output device's UID key.
    private static let deviceKey = "monitor.deviceUID"

    /// The selected output device's cached display name key.
    private static let deviceNameKey = "monitor.deviceName"

    /// The monitor level key.
    private static let levelKey = "monitor.level"

    /// The level a fresh install monitors at once a device is chosen.
    static let defaultLevel: Double = 0.8

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard
    ///   one by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The selected monitor device's UID, or nil when monitoring is off.
    ///
    /// **Nil on a fresh install, deliberately: monitoring starts off.** An
    /// operator monitoring the program mix through speakers with a live
    /// microphone is a feedback howl, so opting in is the honest default —
    /// the muted-strip posture's sibling.
    var deviceUID: String? {
        get { defaults.string(forKey: Self.deviceKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.deviceKey) }
    }

    /// The selected device's display name as discovery last reported it, or
    /// nil when nothing is selected.
    ///
    /// Cached beside the UID for one reason: the device list arrives
    /// asynchronously and a chosen device can be unplugged, so the picker
    /// needs a label for a selection it cannot currently resolve — the
    /// dormant channel strip's cached name, one path over. It is never the
    /// device's identity; ``deviceUID`` alone is.
    var deviceName: String? {
        get { defaults.string(forKey: Self.deviceNameKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.deviceNameKey) }
    }

    /// The monitor level, `0`...`1` — the operator's own listening volume,
    /// which never touches the program mix. An unset value reads
    /// ``defaultLevel`` rather than silence, so the first device chosen is
    /// audible.
    var level: Double {
        get {
            guard defaults.object(forKey: Self.levelKey) != nil else { return Self.defaultLevel }
            return min(1, max(0, defaults.double(forKey: Self.levelKey)))
        }
        nonmutating set { defaults.set(min(1, max(0, newValue)), forKey: Self.levelKey) }
    }
}
