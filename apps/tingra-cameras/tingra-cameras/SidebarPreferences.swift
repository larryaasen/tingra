//
//  SidebarPreferences.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-29.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// One collapsible section of the window's sidebar (``SidebarView``) — the
/// main Tingra app's `SidebarSection`, for this app's two sections.
///
/// A named case per section rather than a raw string, so the persisted key and
/// the `tap` event name are both derived from one closed list — a section
/// added without an entry here does not compile.
enum SidebarSection: String, CaseIterable {
    /// The saved camera presets.
    case presets

    /// The discovered cameras.
    case cameras

    /// The section's `tap` event name, reported when the operator opens or
    /// closes it.
    ///
    /// One name per section rather than a shared name told apart by a param,
    /// so each disclosure's use is independently traceable in the log
    /// (EVENTS.md, "The `tap` convention"). Spelled out in a switch rather
    /// than assembled from the raw value, so the event names are greppable.
    var tapName: String {
        switch self {
        case .presets: "sidebarPresets.disclosure"
        case .cameras: "sidebarCameras.disclosure"
        }
    }

    /// The defaults key the section's expansion persists under — the main
    /// app's key shape.
    var expansionKey: String { "sidebar.\(rawValue).expanded" }
}

/// Which sidebar sections are open: **machine-local preferences**, the main
/// Tingra app's `SidebarPreferences`.
///
/// Every macOS source list an operator has used — Finder, Mail, Xcode —
/// remembers its collapsed sections, so a sidebar that reopened everything
/// each launch would read as a bug rather than as a fresh start.
struct SidebarPreferences {
    /// The defaults database the values live in (injectable, so a test runs
    /// against its own suite rather than the user's).
    private let defaults: UserDefaults

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a section is open.
    ///
    /// A section nothing has been stored for reads **open**, so a fresh
    /// install shows every section and collapsing is something the operator
    /// chooses rather than something they have to undo. `UserDefaults.bool`
    /// alone could not express that — it returns `false` for a missing key —
    /// so the presence of the key is what is checked first.
    ///
    /// - Parameter section: The section to read.
    /// - Returns: Whether it is open.
    func isExpanded(_ section: SidebarSection) -> Bool {
        guard defaults.object(forKey: section.expansionKey) != nil else { return true }
        return defaults.bool(forKey: section.expansionKey)
    }

    /// Records whether a section is open.
    ///
    /// - Parameters:
    ///   - isExpanded: Whether the section is open.
    ///   - section: The section to record.
    func setExpanded(_ isExpanded: Bool, for section: SidebarSection) {
        defaults.set(isExpanded, forKey: section.expansionKey)
    }

    /// Every section that is currently open — what the sidebar seeds its
    /// view-local expansion state from when a window opens.
    ///
    /// - Returns: The open sections.
    func expandedSections() -> Set<SidebarSection> {
        Set(SidebarSection.allCases.filter { isExpanded($0) })
    }
}
