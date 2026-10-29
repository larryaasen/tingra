//
//  CameraPresetStore.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the camera presets persist: `camera-presets.json` in Tingra's
/// Application Support folder, beside the destinations and the stream
/// history (docs/UVC.md, "Camera presets").
///
/// In the host rather than a front end, because the presets are the
/// operator's settings for their cameras, not one front end's: Tingra
/// Cameras saves them today, and any front end that opens a camera reads the
/// same file through this type. A file rather than preferences, because it is
/// a list the operator builds up — the reasoning ``StreamHistoryStore``
/// follows.
///
/// The whole file is rewritten on each change; a preset is a few hundred
/// bytes and changes only when the operator saves, renames, updates, or
/// deletes one.
public struct CameraPresetStore: Sendable {
    /// The file's name.
    public static let fileName = "camera-presets.json"

    /// The file's location.
    public let fileURL: URL

    /// Creates a store over the file in a folder.
    ///
    /// - Parameter directory: The folder (Tingra's Application Support folder
    ///   by default; a test names a temporary one).
    public init(directory: URL = PlugInBundleLoader.standardStateDirectory) {
        self.fileURL = directory.appending(path: Self.fileName)
    }

    /// Reads the presets.
    ///
    /// - Returns: The presets and their default; empty, with no default, when
    ///   there is no file yet.
    /// - Throws: A reading or decoding error when the file exists and cannot
    ///   be read as camera presets.
    public func read() throws -> CameraPresets {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return CameraPresets()
        }
        return try JSONDecoder().decode(CameraPresets.self, from: Data(contentsOf: fileURL))
    }

    /// Writes the presets, replacing the file.
    ///
    /// - Parameter presets: The presets and their default.
    /// - Throws: A directory-creation, encoding, or writing error.
    public func write(_ presets: CameraPresets) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: fileURL, options: [.atomic])
    }

    /// The `.unreadable` sibling ``setAsideUnreadableFile()`` moves an
    /// undecodable file to.
    public var unreadableFileURL: URL { fileURL.appendingPathExtension("unreadable") }

    /// Moves an unreadable file aside — to ``unreadableFileURL``, replacing
    /// any previous one — so the next preset saved starts a fresh file
    /// without destroying whatever the old one held: the rule the stream
    /// history follows.
    ///
    /// - Throws: A file-system error when the move itself is not possible.
    public func setAsideUnreadableFile() throws {
        if FileManager.default.fileExists(atPath: unreadableFileURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: unreadableFileURL)
        }
        try FileManager.default.moveItem(at: fileURL, to: unreadableFileURL)
    }
}
