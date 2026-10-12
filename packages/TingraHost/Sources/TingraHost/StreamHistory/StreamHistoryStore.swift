//
//  StreamHistoryStore.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the stream history persists: `stream-history.json` in Tingra's
/// Application Support folder, beside the destinations it names
/// (ARCHITECTURE.md, "Stream history").
///
/// In the host rather than a front end, because the history is the
/// operator's, not one front end's: every front end that puts a program on
/// air reads and writes the same file through this type. A file rather than
/// preferences, because it is a record that grows by one
/// entry per streamed session, and not the project document, because the
/// history is the operator's across every show — the reasoning the
/// destination store follows (DESTINATIONS.md).
///
/// The whole file is rewritten on each change. An entry is a few hundred
/// bytes and the file changes twice per streamed session, so there is
/// nothing to gain from appending.
public struct StreamHistoryStore: Sendable {
    /// The file's name.
    public static let fileName = "stream-history.json"

    /// The file's location.
    public let fileURL: URL

    /// Creates a store over the file in a folder.
    ///
    /// - Parameter directory: The folder (Tingra's Application Support folder
    ///   by default; a test names a temporary one).
    public init(directory: URL = PlugInBundleLoader.standardStateDirectory) {
        self.fileURL = directory.appending(path: Self.fileName)
    }

    /// What the file holds. The key is spelled out, so the file's shape is
    /// the contract.
    struct Contents: Codable, Equatable {
        /// The streamed sessions, oldest first.
        let sessions: [StreamHistoryEntry]

        /// The JSON keys.
        enum CodingKeys: String, CodingKey {
            case sessions
        }
    }

    /// Reads the history.
    ///
    /// - Returns: The streamed sessions, oldest first; empty when there is
    ///   no file yet.
    /// - Throws: A reading or decoding error when the file exists and cannot
    ///   be read as a history.
    public func read() throws -> [StreamHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Contents.self, from: Data(contentsOf: fileURL)).sessions
    }

    /// Writes the history, replacing the file.
    ///
    /// - Parameter entries: The streamed sessions, oldest first.
    /// - Throws: A directory-creation, encoding, or writing error.
    public func write(_ entries: [StreamHistoryEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Contents(sessions: entries)).write(to: fileURL, options: [.atomic])
    }

    /// The `.unreadable` sibling ``setAsideUnreadableFile()`` moves an
    /// undecodable history to.
    public var unreadableFileURL: URL { fileURL.appendingPathExtension("unreadable") }

    /// Moves an unreadable history aside — to ``unreadableFileURL``,
    /// replacing any previous one — so the next streamed session starts a
    /// fresh history without destroying whatever the file held — the rule
    /// the app follows for an unreadable project document.
    ///
    /// - Throws: A file-system error when the move itself is not possible.
    public func setAsideUnreadableFile() throws {
        if FileManager.default.fileExists(atPath: unreadableFileURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: unreadableFileURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: unreadableFileURL)
    }

    /// Removes the file and its `.unreadable` sibling; a missing file is not
    /// an error.
    ///
    /// - Throws: The file-system error when a file exists and cannot be
    ///   removed.
    public func remove() throws {
        for url in [fileURL, unreadableFileURL]
        where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
