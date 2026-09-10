//
//  LibraryPreferences.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the Library panel's height persists across launches — the
/// sidebar-sections precedent (``SidebarPreferences``): the splitter between
/// the layer inspector and the Library is part of the window's shape the
/// operator set, so it comes back the way it was left (ARCHITECTURE.md,
/// "Media inputs and the Library's Media tab").
struct LibraryPreferences {
    /// The height the Library opens at on a fresh install: enough for the
    /// heading and four or five rows without starving the inspector above.
    static let defaultHeight: CGFloat = 260

    /// The shortest the Library may be dragged: the heading and two rows.
    static let minimumHeight: CGFloat = 140

    /// The least the layer inspector above keeps: its header and one unit
    /// of controls, so the Library cannot push it off the column.
    static let minimumInspectorHeight: CGFloat = 200

    /// The defaults key the height persists under.
    static let heightKey = "library.height"

    /// The defaults database the value lives in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The persisted height, or the default when none has been stored or the
    /// stored value is not a usable number.
    func height() -> CGFloat {
        guard let stored = defaults.object(forKey: Self.heightKey) as? Double, stored.isFinite, stored > 0 else {
            return Self.defaultHeight
        }
        return CGFloat(stored)
    }

    /// Records the Library's height.
    ///
    /// - Parameter height: The height to persist.
    func setHeight(_ height: CGFloat) {
        defaults.set(Double(height), forKey: Self.heightKey)
    }

    /// The height the Library may actually take in a column of the given
    /// height: never below ``minimumHeight``, and never so tall that the
    /// inspector above drops under ``minimumInspectorHeight`` — unless the
    /// column is too short for both, when the Library's minimum wins,
    /// because a Library that cannot show a row is not a Library.
    ///
    /// - Parameters:
    ///   - height: The requested height.
    ///   - columnHeight: The trailing sidebar's total height.
    /// - Returns: The clamped height.
    static func clamped(_ height: CGFloat, in columnHeight: CGFloat) -> CGFloat {
        let ceiling = max(minimumHeight, columnHeight - minimumInspectorHeight)
        return min(max(height, minimumHeight), ceiling)
    }
}
