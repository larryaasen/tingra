//
//  EngineModel+Destinations.swift
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
import TingraPlugInKit

/// Destinations: the list a stream goes to, their stream keys, and their edits.
extension EngineModel {
    /// The stream key stored for a destination, or nil when none is stored.
    ///
    /// Read from secure storage so the Streaming settings pane can prefill
    /// its key fields, and so ``startStreaming()`` can carry each key to its
    /// destination, without the key ever passing through the project
    /// document. A read failure is reported and treated as "no stored key" —
    /// never a crash.
    ///
    /// - Parameter id: The destination's stable id.
    /// - Returns: The stored stream key, or nil.
    func storedStreamKey(for id: ProjectDestinationID) -> String? {
        do {
            return try secureStorage.secret(forAccount: Self.secureStorageAccount(for: id))
        } catch {
            eventBus.error(
                "securestore.read",
                domain: .output,
                params: ["error": .string(String(describing: error))]
            )
            return nil
        }
    }

    /// Merges the operator's saved destinations with this project's
    /// references into the panel's rows (DESTINATIONS.md).
    ///
    /// Runs once at boot, after the document is read: the store is an actor
    /// and answers asynchronously, while the document arrives synchronously.
    /// A store that cannot be read is reported and treated as empty — the show
    /// still opens, with no destinations, rather than not opening at all.
    func loadDestinations() async {
        do {
            let saved = try await destinationStore.destinations()
            destinations = DestinationEdit.edits(saved: saved, references: projectDestinationReferences)
        } catch {
            eventBus.error(
                "destination.load",
                domain: .output,
                params: ["error": .string(String(describing: error))]
            )
            destinations = []
        }
        projectDestinationReferences = nil
    }

    /// Writes one row through to the operator's store, adding it when new and
    /// updating it otherwise.
    ///
    /// A row whose URL is not yet usable is **not** written: a half-typed
    /// `rtm` is not a destination, and the store is shared with every other
    /// project and the daemon. The row keeps its place in the panel until the
    /// URL resolves, then lands.
    ///
    /// - Parameter edit: The row to write.
    private func syncDestinationToStore(_ edit: DestinationEdit) async {
        guard let destination = edit.storedDestination else { return }
        do {
            if try await destinationStore.destination(id: destination.id) == nil {
                try await destinationStore.add(destination)
            } else {
                try await destinationStore.update(destination)
            }
        } catch {
            eventBus.error(
                "destination.save",
                domain: .output,
                params: ["error": .string(String(describing: error))]
            )
        }
    }

    /// Stores the stream key the operator typed for a destination, or clears
    /// the stored key when the text is empty — the Streaming settings pane's
    /// write path, called as the key field changes.
    ///
    /// The Keychain is the only place a key lives once the destination rows
    /// moved out of the main window (2026-09-08): the toolbar's Start
    /// Streaming reads each key back from here at the click rather than
    /// collecting field text across windows, so the key never becomes model
    /// state, project content, or an event param. Best effort, like every
    /// secure-storage write: a Keychain error is reported on the bus and the
    /// field keeps its text.
    ///
    /// - Parameters:
    ///   - streamKey: The key as typed, or empty to clear the stored key.
    ///   - id: The destination whose key this is.
    func setStreamKey(_ streamKey: String, for id: ProjectDestinationID) {
        persistStreamKey(streamKey, for: id)
    }

    /// Adds an empty destination to the list and autosaves.
    ///
    /// The new row reaches neither the store nor the project file until its
    /// URL is usable (``DestinationEdit/storedDestination``), so an abandoned
    /// row never becomes an operator-global destination.
    func addDestination() {
        destinations.append(DestinationEdit())
        eventBus.event("destination.added", domain: .output, params: ["destinations": .int(destinations.count)])
        scheduleAutosave()
    }

    /// Adds a destination started from a template — the service's name and
    /// URL filled in — and autosaves (DESTINATIONS.md, "What the app does
    /// with it").
    ///
    /// Unlike an empty row, its URL is usable from the start, so it is
    /// written through to the operator's store at once, like any edit that
    /// completes a URL.
    ///
    /// - Parameter template: The service to start from.
    /// - Returns: The new destination's id, so the pane can put the cursor in
    ///   its stream key field — the one thing the operator still has to
    ///   fetch from the service.
    @discardableResult
    func addDestination(from template: DestinationTemplate) -> ProjectDestinationID {
        let destination = DestinationEdit(template: template)
        destinations.append(destination)
        eventBus.event(
            "destination.added",
            domain: .output,
            params: ["destinations": .int(destinations.count), "template": .string(template.id)]
        )
        scheduleAutosave()
        Task { await syncDestinationToStore(destination) }
        return destination.id
    }

    /// Removes a destination and clears its stored stream key — deleting a
    /// destination should not leave its secret behind in the Keychain.
    ///
    /// **Removes it for every project**, not just this one: destinations are
    /// operator-global, so this deletes the saved record itself. The panel's
    /// confirmation is what makes that safe (ARCHITECTURE.md, "Multiple
    /// destinations").
    ///
    /// - Parameter id: The destination to remove.
    func removeDestination(_ id: ProjectDestinationID) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        let removed = destinations.remove(at: index)
        persistStreamKey("", for: id)
        eventBus.event("destination.removed", domain: .output, params: ["destinations": .int(destinations.count)])
        scheduleAutosave()
        Task { [destinationStore, eventBus] in
            do {
                try await destinationStore.remove(id: removed.storeID)
            } catch {
                eventBus.error(
                    "destination.remove",
                    domain: .output,
                    params: ["error": .string(String(describing: error))]
                )
            }
        }
    }

    /// Updates a destination's typed URL and autosaves.
    ///
    /// The id is untouched, so the destination keeps the stream key already
    /// filed under it — the reason keys are keyed by id and not by URL.
    ///
    /// - Parameters:
    ///   - text: The URL as typed.
    ///   - id: The destination to update.
    func setDestinationURL(_ text: String, for id: ProjectDestinationID) {
        updateDestination(id) { $0.urlText = text }
    }

    /// Updates a destination's operator-facing name and autosaves.
    ///
    /// - Parameters:
    ///   - name: The new label.
    ///   - id: The destination to update.
    func setDestinationName(_ name: String, for id: ProjectDestinationID) {
        updateDestination(id) { $0.name = name }
    }

    /// Enables or disables a destination and autosaves. A disabled
    /// destination keeps everything it has but contributes no leg to the next
    /// stream.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether it is streamed to.
    ///   - id: The destination to update.
    func setDestinationEnabled(_ isEnabled: Bool, for id: ProjectDestinationID) {
        updateDestination(id, writesToStore: false) { $0.isEnabled = isEnabled }
    }

    /// Applies an edit to one destination, resets a stale terminal status,
    /// and schedules the debounced autosave. A no-op for an unknown id.
    ///
    /// - Parameters:
    ///   - id: The destination to update.
    ///   - edit: The mutation to apply.
    private func updateDestination(
        _ id: ProjectDestinationID,
        writesToStore: Bool = true,
        _ edit: (inout DestinationEdit) -> Void
    ) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        edit(&destinations[index])
        // An edit after a failed or finished run clears the stale banner, so
        // the panel does not keep reporting the previous attempt's fate.
        if !isStreaming { streamStatus = .idle }
        scheduleAutosave()
        // The name and URL belong to the operator's store; the enabled flag is
        // this project's alone and never travels there.
        guard writesToStore else { return }
        let updated = destinations[index]
        Task { await syncDestinationToStore(updated) }
    }

    /// The secure-storage account a destination's stream key is filed under.
    ///
    /// Keyed by the destination's **id**, not its URL: two destinations can
    /// share an ingest URL with different keys, and editing a URL would
    /// orphan a key stored under the old one (ARCHITECTURE.md, "Multiple
    /// destinations"). The prefix keeps these items distinct from any other
    /// secret the host files later.
    ///
    /// - Parameter id: The destination's stable id.
    /// - Returns: The account string.
    private static func secureStorageAccount(for id: ProjectDestinationID) -> String {
        // Delegated rather than duplicated: the daemon files keys under the
        // store's convention, and a second copy of the format here is exactly
        // how the two would drift apart.
        DestinationStore.secureStorageAccount(for: DestinationID(rawValue: id.rawValue))
    }

    /// Stores the stream key for a destination, or clears it when the key is
    /// empty — best effort. A secure-storage error is reported on the bus (no
    /// secret in the message) and swallowed: the in-memory key still drives
    /// this session's stream.
    ///
    /// - Parameters:
    ///   - streamKey: The key to store, or empty to clear the stored key.
    ///   - id: The destination whose key this is.
    private func persistStreamKey(_ streamKey: String, for id: ProjectDestinationID) {
        let account = Self.secureStorageAccount(for: id)
        do {
            if streamKey.isEmpty {
                try secureStorage.removeSecret(forAccount: account)
            } else {
                try secureStorage.setSecret(streamKey, forAccount: account)
            }
        } catch {
            eventBus.error(
                "securestore.write",
                domain: .output,
                params: ["error": .string(String(describing: error))]
            )
        }
    }
}
