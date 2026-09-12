//
//  SnapshotListing.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import UniformTypeIdentifiers

/// What the snapshots folder holds: the one reading the Library's Snapshots
/// tab lists and the Data settings pane counts, so the two cannot disagree
/// about what a snapshot is (ARCHITECTURE.md, "Snapshots").
///
/// The **image files directly in the folder** — not recursive, hidden files
/// skipped — newest first. **Not filtered by name**: a renamed snapshot is
/// still a snapshot, and a folder the operator chose is theirs to fill.
enum SnapshotListing {
    /// One image in the folder, with the facts the list shows.
    struct File: Equatable {
        /// The file.
        let url: URL

        /// When it was last modified, if the file system said.
        let modifiedAt: Date?

        /// Its size in bytes, if the file system said.
        let byteCount: Int64?
    }

    /// The image files directly in a folder, newest first — ties, as within
    /// one second, broken by name, descending, so a suffixed name follows its
    /// sibling's order.
    ///
    /// - Parameter folder: The snapshots folder.
    /// - Returns: The files, or none for a folder that does not exist yet.
    static func files(in folder: URL) -> [File] {
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
                type.conforms(to: .image)
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
}
