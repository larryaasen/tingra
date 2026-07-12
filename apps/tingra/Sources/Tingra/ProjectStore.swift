//
//  ProjectStore.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition

/// Loads and saves the app's project document — the saved file for a whole
/// show (GLOSSARY.md, "Project").
///
/// This iteration keeps a single autosaved project at a fixed location under
/// the app's Application Support directory (the established Tingra home, next
/// to the daemon's socket); explicit Save/Open menu commands and multiple
/// projects arrive with the document UI (see ARCHITECTURE.md, "Project
/// save/load"). The document is JSON — pretty-printed with sorted keys so it
/// diffs and inspects cleanly — written atomically so a crash mid-save never
/// leaves a truncated file.
///
/// The directory is injectable so tests exercise real load/save round-trips
/// against a temporary directory, never the user's own project file.
struct ProjectStore {
    /// The file name of the single autosaved project. `.tingraproject` is the
    /// project document's extension; the content is JSON.
    static let fileName = "Default.tingraproject"

    /// The directory holding the project file.
    let directoryURL: URL

    /// The project file's location.
    let fileURL: URL

    /// Creates a store rooted at the given directory.
    ///
    /// - Parameter directory: The directory holding the project file
    ///   (default: `~/Library/Application Support/Tingra`).
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Tingra")) {
        self.directoryURL = directory
        self.fileURL = directory.appending(path: Self.fileName)
    }

    /// Loads the project document, or returns nil when no file exists yet (a
    /// fresh install — the caller seeds a new project).
    ///
    /// - Returns: The decoded project, or nil when there is no file.
    /// - Throws: A reading or `DecodingError` when the file exists but cannot
    ///   be read as a project document — including a document written by a
    ///   newer Tingra (see `Project.init(from:)`). Callers set the unreadable
    ///   file aside (``setAsideUnreadableFile()``) rather than overwriting it.
    func load() throws -> Project? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Project.self, from: data)
    }

    /// Saves the project document, creating the directory if needed and
    /// writing atomically.
    ///
    /// - Parameter project: The project to save.
    /// - Throws: A directory-creation, encoding, or writing error.
    func save(_ project: Project) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: fileURL, options: [.atomic])
    }

    /// Moves an unreadable project file aside — to a sibling with an
    /// `.unreadable` extension appended, replacing any previous one — so the
    /// app can seed a fresh project without silently destroying whatever the
    /// file held (the operator can recover or report it).
    ///
    /// - Returns: The location the file was moved to.
    /// - Throws: A file-system error when the move itself is not possible.
    @discardableResult
    func setAsideUnreadableFile() throws -> URL {
        let destination = fileURL.appendingPathExtension("unreadable")
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }
}
