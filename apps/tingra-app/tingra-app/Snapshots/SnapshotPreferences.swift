//
//  SnapshotPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the operator's snapshots go: **machine-local preferences**, for the
/// ``RecordingPreferences`` reasons unchanged (ARCHITECTURE.md, "Snapshots").
/// Not the document — which folder on this Mac holds the stills is not part
/// of the show — and not session state, since it does not change between
/// launches.
struct SnapshotPreferences {
    /// The defaults database the value lives in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The snapshots folder key.
    static let folderKey = "snapshot.folderPath"

    /// The name of the folder a fresh install saves into, inside `~/Pictures`.
    static let defaultFolderName = "Tingra Snapshots"

    /// Where a fresh install saves snapshots: `~/Pictures/Tingra Snapshots`.
    ///
    /// A **dedicated** folder rather than `~/Pictures` itself, because the
    /// Library's Snapshots tab lists the folder, and `~/Pictures` would list
    /// every picture the operator owns. Under `~/Pictures` because Desktop,
    /// Documents, and Downloads are TCC-protected on macOS 15 and would put a
    /// permission prompt in front of the first snapshot — the reasoning that
    /// put recordings in `~/Movies`.
    static var defaultFolder: URL {
        .picturesDirectory.appending(path: defaultFolderName, directoryHint: .isDirectory)
    }

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The folder snapshots are written into — the default until the
    /// operator chooses one, and again for a stored path that is empty.
    ///
    /// Stored as a plain path: the app is not sandboxed (CLAUDE.md), so a
    /// folder the operator picks needs no security-scoped bookmark.
    var folder: URL {
        get {
            guard let path = defaults.string(forKey: Self.folderKey), !path.isEmpty else {
                return Self.defaultFolder
            }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        nonmutating set { defaults.set(newValue.path(percentEncoded: false), forKey: Self.folderKey) }
    }
}
