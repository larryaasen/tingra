//
//  EngineModel+Library.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition
import TingraEventBus
import TingraHost

/// The Library's files: finding a file's media item and moving a snapshot or recording to the Trash.
extension EngineModel {
    /// The project's media item for a file, if the project uses it — what
    /// the Library's Add to Media disables on and Move to Trash confirms on.
    ///
    /// - Parameter url: The file.
    /// - Returns: The item, or nil when the project does not use the file.
    func mediaItem(forFile url: URL) -> ProjectMedia? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return media.first { $0.path == path }
    }

    /// Moves a snapshot to the Trash, never a permanent delete. When the
    /// project uses the file as media, its input is unregistered so its layers
    /// show nothing (the missing-media semantic); the item stays, dormant.
    ///
    /// - Parameter url: The snapshot file.
    /// - Returns: Nil on success, or the reason in the operator's words.
    func trashSnapshot(at url: URL) async -> String? {
        await trashLibraryFile(
            at: url, errorName: "snapshot.trash", trashedName: "snapshot.trashed", domain: .composition,
            revision: \.snapshotRevision)
    }

    /// Moves a recording to the Trash, on the snapshots' terms
    /// (``trashSnapshot(at:)``), except the take being written, which is
    /// refused: trashing a file under its writer would lose the take and
    /// leave the session writing into the Trash (ARCHITECTURE.md, "The
    /// Recordings tab"). The Library disables that row's item, so the refusal
    /// here is for any other caller.
    ///
    /// - Parameter url: The recording file.
    /// - Returns: Nil on success, or the reason in the operator's words.
    func trashRecording(at url: URL) async -> String? {
        guard !isBeingRecorded(url) else {
            eventBus.error(
                "recording.trash",
                domain: .output,
                params: ["file": .string(url.lastPathComponent), "reason": .string("recording")]
            )
            return String(
                localized:
                    "“\(url.lastPathComponent)” is still being recorded. Stop the recording before moving it to the Trash.",
                comment:
                    "Reason a recording could not be moved to the Trash: it is the take being recorded; the placeholder is the file's name"
            )
        }
        return await trashLibraryFile(
            at: url, errorName: "recording.trash", trashedName: "recording.trashed", domain: .output,
            revision: \.recordingRevision)
    }

    /// Whether a file is the recording being written — named by the last
    /// `recording.started`, or the file a session just opened whose event has
    /// not arrived yet.
    ///
    /// - Parameter url: The file.
    /// - Returns: True when a recording session is writing that file.
    func isBeingRecorded(_ url: URL) -> Bool {
        if let fileBeingRecorded, FolderListing.isSameFile(fileBeingRecorded, url) { return true }
        if recordSession != nil, let recordingURL, FolderListing.isSameFile(recordingURL, url) { return true }
        return false
    }

    /// Moves a file one of the Library's file tabs lists to the Trash: the one
    /// path snapshots and recordings share, so the two tabs cannot differ.
    /// The events name the file, never its folder (the media rule). When the
    /// project uses the file as media, its input is unregistered at once.
    ///
    /// - Parameters:
    ///   - url: The file.
    ///   - errorName: The error event reported when the move is refused.
    ///   - trashedName: The event reported when the file is in the Trash.
    ///   - domain: The domain both events belong to.
    ///   - revision: The counter the tab re-reads on.
    /// - Returns: Nil on success, or the reason in the operator's words.
    private func trashLibraryFile(
        at url: URL, errorName: String, trashedName: String, domain: EventDomain,
        revision: ReferenceWritableKeyPath<EngineModel, Int>
    ) async -> String? {
        let item = mediaItem(forFile: url)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            eventBus.error(
                errorName,
                domain: domain,
                params: ["file": .string(url.lastPathComponent), "error": .string(String(describing: error))]
            )
            return error.localizedDescription
        }
        eventBus.event(
            trashedName,
            domain: domain,
            params: ["file": .string(url.lastPathComponent), "usedAsMedia": .bool(item != nil)]
        )
        self[keyPath: revision] += 1
        if let item {
            await registry.unregister(item.id.inputID)
            await readDeviceLists()
            await refreshMixerStrips()
            await reconfigure()
        }
        return nil
    }
}
