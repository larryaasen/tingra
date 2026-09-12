//
//  SnapshotFilename.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Names the file a snapshot is written to: what was saved and when —
/// `Tingra Program 2026-09-10 14.03.12.png` — never overwriting an earlier
/// one (ARCHITECTURE.md, "Snapshots").
///
/// The recording name's rules, one kind of file over: the same prefix and
/// the same locale-independent timestamp (``RecordingFilename/timestamp(at:)``,
/// shared rather than copied), and a name already on disk takes a numeric
/// suffix rather than replacing what is there. The **subject** — Program,
/// Preview, an input's name, "<input> Layer" — is the one part that is
/// localized, the way macOS localizes its own screenshot names; the caller
/// supplies it already in the operator's language.
///
/// `nonisolated`: the ``SnapshotWriter`` actor names each file just before
/// writing it, so two snapshots in one second are named one after the other.
nonisolated enum SnapshotFilename {
    /// The file extension every snapshot carries — PNG is the one format.
    static let fileExtension = "png"

    /// The most UTF-8 bytes a subject keeps. A file name may be 255 bytes on
    /// APFS; a long text input's name must not push the timestamp and the
    /// suffix past that, and a budget in bytes, not characters, is the one
    /// that holds for any script.
    static let maximumSubjectByteCount = 120

    /// A subject made safe for a file name: `/` and `:` (the two characters a
    /// macOS path cannot hold in a name, the second because the Finder
    /// shows it as `/`) become `-`, line breaks and tabs become spaces, the
    /// ends are trimmed, and a long subject is cut at a character boundary
    /// within ``maximumSubjectByteCount``.
    ///
    /// - Parameter subject: The subject as the operator reads it.
    /// - Returns: The subject as the file name carries it.
    static func sanitized(_ subject: String) -> String {
        var cleaned = ""
        for character in subject {
            if character == "/" || character == ":" {
                cleaned.append("-")
            } else if character.isNewline || character == "\t" {
                cleaned.append(" ")
            } else {
                cleaned.append(character)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard cleaned.utf8.count > maximumSubjectByteCount else { return cleaned }
        var truncated = ""
        for character in cleaned {
            guard truncated.utf8.count + character.utf8.count <= maximumSubjectByteCount else { break }
            truncated.append(character)
        }
        return truncated.trimmingCharacters(in: .whitespaces)
    }

    /// The stem for a subject at a moment: `Tingra Program 2026-09-10 14.03.12`.
    /// A subject that sanitizes to nothing is left out rather than leaving a
    /// double space.
    ///
    /// - Parameters:
    ///   - subject: What was saved, in the operator's language.
    ///   - date: The moment the snapshot was asked for.
    /// - Returns: The stem, without an extension.
    static func stem(subject: String, at date: Date) -> String {
        let cleaned = sanitized(subject)
        let timestamp = RecordingFilename.timestamp(at: date)
        guard !cleaned.isEmpty else { return "\(RecordingFilename.prefix) \(timestamp)" }
        return "\(RecordingFilename.prefix) \(cleaned) \(timestamp)"
    }

    /// Picks the URL a snapshot should be written to.
    ///
    /// - Parameters:
    ///   - folder: The snapshots folder.
    ///   - subject: What was saved, in the operator's language.
    ///   - date: The moment the snapshot was asked for.
    ///   - exists: Whether a URL is already taken — injected so tests decide
    ///     without a disk.
    /// - Returns: A URL that was not taken when it was checked.
    static func url(
        in folder: URL,
        subject: String,
        at date: Date,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> URL {
        let stem = stem(subject: subject, at: date)
        let first = folder.appending(path: "\(stem).\(fileExtension)")
        guard exists(first) else { return first }
        // A held ⌥⌘S repeats within the second: suffix rather than replace.
        // Bounded by how many snapshots can share a second, so it terminates
        // on any real disk.
        for suffix in 2... {
            let candidate = folder.appending(path: "\(stem) \(suffix).\(fileExtension)")
            if !exists(candidate) { return candidate }
        }
        return first
    }
}
