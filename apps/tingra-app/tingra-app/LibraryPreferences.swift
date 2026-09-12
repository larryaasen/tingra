//
//  LibraryPreferences.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI

/// Which tab the Library panel shows (GLOSSARY.md, "Library"): the
/// project's media, or the snapshots folder (ARCHITECTURE.md, "Snapshots").
enum LibraryTab: String, CaseIterable, Identifiable {
    /// The project's media files.
    case media

    /// The images in the snapshots folder.
    case snapshots

    /// The tab itself, for `ForEach`.
    var id: Self { self }

    /// The tab's name on the segmented control.
    var title: Text {
        switch self {
        case .media:
            Text("Media", comment: "Library tab listing the project's media files")
        case .snapshots:
            Text(
                "Snapshots",
                comment:
                    "Snapshots: the still images saved from monitors — the Library tab, the Data settings kind, and the General settings heading"
            )
        }
    }
}

/// Where the Library panel's height and tab persist across launches — the
/// sidebar-sections precedent (``SidebarPreferences``): the splitter between
/// the layer inspector and the Library is part of the window's shape the
/// operator set, so it comes back the way it was left (ARCHITECTURE.md,
/// "Media inputs and the Library's Media tab"), and so does the tab they
/// were on ("Snapshots").
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

    /// The defaults key the tab persists under.
    static let tabKey = "library.tab"

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

    /// The persisted tab, or Media when none has been stored or the stored
    /// value names no tab this build knows.
    func tab() -> LibraryTab {
        defaults.string(forKey: Self.tabKey).flatMap(LibraryTab.init(rawValue:)) ?? .media
    }

    /// Records the tab the Library shows.
    ///
    /// - Parameter tab: The tab to persist.
    func setTab(_ tab: LibraryTab) {
        defaults.set(tab.rawValue, forKey: Self.tabKey)
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
