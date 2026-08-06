//
//  RecordingPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Where the operator's recordings go: **machine-local preferences**, not the
/// project document and not session state (ARCHITECTURE.md, "Recording in the
/// app").
///
/// The `MonitorPreferences` reasoning applies unchanged, one sink over. The
/// **document** would be wrong — which folder on this Mac holds the
/// recordings is not part of the show, the same test that keeps stream keys,
/// the active shot, and the staged shot out of it, and a project carried to
/// another machine would name a folder that does not exist. **Session-only**
/// would be wrong too: an operator's recordings folder does not change
/// between launches, so re-picking it every launch would be a defect rather
/// than a discipline.
struct RecordingPreferences {
    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The recordings folder key.
    private static let folderKey = "recording.folderPath"

    /// The container-format key.
    private static let containerKey = "recording.container"

    /// Where a fresh install records to.
    ///
    /// `~/Movies` deliberately, over Desktop or Documents: those are
    /// TCC-protected on macOS 15 and would put a permission prompt in front
    /// of the operator's very first recording, where `~/Movies` is not
    /// protected and is already where macOS puts video.
    static var defaultFolder: URL { .moviesDirectory }

    /// The container a fresh install records into — QuickTime `.mov`, the
    /// native macOS choice.
    static let defaultContainer: RecordingFile.Container = .mov

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The folder recordings are written into.
    ///
    /// Stored as a plain path: the app is not sandboxed (CLAUDE.md), so a
    /// folder the operator picks needs no security-scoped bookmark to stay
    /// reachable across launches.
    var folder: URL {
        get {
            guard let path = defaults.string(forKey: Self.folderKey), !path.isEmpty else {
                return Self.defaultFolder
            }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        nonmutating set { defaults.set(newValue.path(percentEncoded: false), forKey: Self.folderKey) }
    }

    /// The container format recordings are muxed into. An unrecognized stored
    /// value reads as the default rather than throwing away the recording.
    var container: RecordingFile.Container {
        get {
            guard
                let raw = defaults.string(forKey: Self.containerKey),
                let container = RecordingFile.Container(rawValue: raw)
            else {
                return Self.defaultContainer
            }
            return container
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.containerKey) }
    }
}
