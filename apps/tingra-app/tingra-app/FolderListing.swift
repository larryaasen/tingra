//
//  FolderListing.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import UniformTypeIdentifiers

/// What a folder Tingra writes into holds: the one reading the Library's
/// file tabs list and the Data settings pane counts, so the two cannot
/// disagree about what a snapshot or a recording is (ARCHITECTURE.md,
/// "Snapshots" and "The Recordings tab").
///
/// The **files directly in the folder whose type conforms to one content
/// type** — images for the snapshots folder, movies for the recordings
/// folder — not recursive, hidden files skipped, newest first. **Not
/// filtered by name**: a renamed snapshot or take is still one, and a folder
/// the operator chose is theirs to fill.
///
/// It was `SnapshotListing` until the Recordings tab gave it a second folder
/// to read (2026-09-12); the reading is the same job with one parameter.
enum FolderListing {
    /// One file in the folder, with the facts the list shows.
    struct File: Equatable {
        /// The file.
        let url: URL

        /// When it was last modified, if the file system said.
        let modifiedAt: Date?

        /// Its size in bytes, if the file system said.
        let byteCount: Int64?
    }

    /// The files directly in a folder that conform to a content type, newest
    /// first — ties, as within one second, broken by name, descending, so a
    /// suffixed name follows its sibling's order.
    ///
    /// - Parameters:
    ///   - folder: The folder to read.
    ///   - contentType: The type a file must conform to (`.image` for
    ///     snapshots, `.movie` for recordings).
    /// - Returns: The files, or none for a folder that does not exist yet.
    static func files(in folder: URL, conformingTo contentType: UTType) -> [File] {
        let keys: [URLResourceKey] = [
            .contentTypeKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
        ]
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let files = contents.compactMap { url -> File? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
                type.conforms(to: contentType)
            else { return nil }
            return File(
                url: url, modifiedAt: values.contentModificationDate, byteCount: values.fileSize.map(Int64.init))
        }
        return files.sorted { lhs, rhs in
            let left = lhs.modifiedAt ?? .distantPast
            let right = rhs.modifiedAt ?? .distantPast
            guard left == right else { return left > right }
            // Compared without the extension, so "… 14.03.12 2" sorts after
            // "… 14.03.12" rather than the space losing to the dot.
            let leftName = lhs.url.deletingPathExtension().lastPathComponent
            let rightName = rhs.url.deletingPathExtension().lastPathComponent
            return leftName.localizedStandardCompare(rightName) == .orderedDescending
        }
    }

    /// Whether two file URLs name the same file, whatever the spelling —
    /// `/var` against `/private/var`, a trailing `.` component — which is how
    /// a listed file is matched to the recording being written.
    ///
    /// - Parameters:
    ///   - lhs: One file.
    ///   - rhs: The other.
    /// - Returns: True when both resolve to the same path.
    nonisolated static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }
}
