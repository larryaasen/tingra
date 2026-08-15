//
//  DestinationStore.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-08-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus
import TingraPlugInKit

/// A saved destination's stable identity — what its stream key is filed under
/// in secure storage, and what a `destination` selector matches outright.
///
/// The id is minted once, when the operator files the destination, and never
/// changes: editing a destination's URL must not orphan its key
/// (DESTINATIONS.md, "The store").
public struct DestinationID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string — a UUID by default, or a caller-chosen stable
    /// token.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a fresh, unique identifier (a new UUID string).
    public init() {
        self.rawValue = UUID().uuidString
    }
}

/// One of the operator's saved destinations: where a program can be streamed
/// to, minus the secret (GLOSSARY.md, "Destination"; DESTINATIONS.md).
///
/// **Operator-global, not per-project.** A Twitch account is not per-show, so
/// the destination itself — id, name, URL, and key — is filed once by the
/// operator and every surface resolves it by name or id. What stays with a
/// project is the *use* of a destination: which ones a show streams to, and
/// whether each is enabled, referencing this record by id.
///
/// Deliberately **key-free**: the stream key is a secret and lives only in the
/// host's Keychain-backed ``SecureStorage``, under the account
/// ``DestinationStore/secureStorageAccount(for:)`` names.
public struct StoredDestination: Sendable, Equatable, Codable, Identifiable {
    /// The destination's stable identity.
    public let id: DestinationID

    /// The operator's label for it ("Twitch", "YouTube backup") — what
    /// "stream to my Twitch" resolves against. Not a secret.
    public let name: String

    /// The RTMP(S) or SRT destination URL. The stream key is never part of it.
    public let url: URL

    /// Creates a saved destination.
    ///
    /// - Parameters:
    ///   - id: The stable identity (default: a fresh one).
    ///   - name: The operator's label.
    ///   - url: The destination URL.
    public init(id: DestinationID = DestinationID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }
}

/// A failure from ``DestinationStore``. Every case is recoverable and
/// developer/agent-facing — the store never crashes the host over a bad file
/// or a Keychain hiccup (CLAUDE.md, never-crash rule) — and no case carries a
/// stream key or any part of one.
public enum DestinationStoreError: Error, Equatable, CustomStringConvertible {
    /// No saved destination matches the selector.
    case notFound(selector: String)

    /// A name selector matched more than one destination; the names carry the
    /// matches for the error message.
    case ambiguous(selector: String, matches: [String])

    /// The destinations file exists but could not be read as a destinations
    /// document. The store never overwrites it — the operator's file is left
    /// exactly as it was so it can be inspected or recovered.
    case unreadableStore(path: String, reason: String)

    /// The destinations file could not be written.
    case unwritableStore(path: String, reason: String)

    /// A destination was added under an id another saved destination already
    /// holds. Ids are the account a stream key is filed under, so reusing one
    /// would give two destinations the same key.
    case duplicateID(DestinationID)

    /// A destination's stream key is filed but could not be read out of
    /// secure storage — in practice, an **unsigned development build**, which
    /// carries no entitlements and so cannot join the shared keychain access
    /// group (DESTINATIONS.md, "Key sharing between the app and the daemon").
    case keyUnreadable(name: String, underlying: SecureStorageError)

    /// A developer/agent-facing description naming the cause and the fix;
    /// carries no secret value.
    public var description: String {
        switch self {
        case .notFound(let selector):
            return """
                No saved destination matches '\(selector)'. Call destinations_list to see the operator's \
                destinations; a selector is a destination id or a name that matches exactly one of them. \
                Destinations are created in the Tingra app, not by an agent.
                """
        case .ambiguous(let selector, let matches):
            return """
                The destination selector '\(selector)' matches more than one saved destination: \
                \(matches.joined(separator: ", ")). Use a longer name or the id from destinations_list \
                to pick one.
                """
        case .unreadableStore(let path, let reason):
            return """
                The destinations file at \(path) could not be read (\(reason)). It has been left \
                untouched — nothing was overwritten. Repair or remove the file to continue; saved \
                destinations are also re-creatable in the Tingra app.
                """
        case .unwritableStore(let path, let reason):
            return "The destinations file at \(path) could not be written (\(reason))."
        case .duplicateID(let id):
            return """
                A destination with id '\(id.rawValue)' is already saved. Ids are the account a stream key is \
                filed under, so two destinations cannot share one — update the saved destination instead of \
                adding a second under its id.
                """
        case .keyUnreadable(let name, let underlying):
            return """
                The stream key for destination '\(name)' is filed but could not be read from secure \
                storage (\(underlying)). An unsigned development build carries no entitlements and so \
                cannot join Tingra's shared keychain access group; run a signed binary — the app, or a \
                tingra-cli built by scripts/release-cli-package.sh — to reach saved keys. Destination names and \
                URLs resolve either way, and a raw 'url'/'key' pair still streams.
                """
        }
    }
}

extension DestinationStoreError {
    /// The stable error identifier this error reports under (see CLI.md,
    /// "Error identifiers").
    ///
    /// The two selector failures mirror `inputNotFound`/`inputAmbiguous`, and
    /// a duplicate id is a caller's bad argument. The rest are platform
    /// failures — not the caller's input and not the network — which is what
    /// `pipelineError` means; no new identifier is minted for them, because
    /// an agent's recourse is identical (report the message, which names the
    /// fix) and the registry is append-only.
    public var identifier: ErrorIdentifier {
        switch self {
        case .notFound: return .destinationNotFound
        case .ambiguous: return .destinationAmbiguous
        case .duplicateID: return .invalidArgument
        case .unreadableStore, .unwritableStore, .keyUnreadable: return .pipelineError
        }
    }
}

/// Store errors carry their identifiers under `IdentifiedError`, so the
/// MCP/Control service can map them without a concrete type switch.
extension DestinationStoreError: IdentifiedError {}

/// The operator's destination store: the named destinations every surface —
/// the app, the CLI, and the MCP daemon — resolves "my Twitch" against
/// (DESTINATIONS.md).
///
/// A **host service**, not a plug-in, by the boundary test in CLAUDE.md:
/// removing it breaks destination resolution for every surface, not one
/// capability. It sits in Platform/Infrastructure beside ``SecureStorage``,
/// which it builds on.
///
/// Two stores, one record:
///
/// - **Names and URLs are not secrets** and live in a JSON document at
///   `~/Library/Application Support/Tingra/destinations.json` — an array of
///   `{id, name, url}` with stable camelCase keys, pretty-printed with sorted
///   keys so it diffs and inspects cleanly, written atomically so a crash
///   mid-save never truncates it.
/// - **Keys stay in the host's Keychain-backed ``SecureStorage``**, under the
///   `destination:<id>` account convention the app already uses. A destination
///   with no stored key is legal (keyless local endpoints stream fine), so
///   listings report ``hasKey(for:)`` rather than implying one is always there.
///
/// **Every read goes to the file, and nothing is cached.** The app and the
/// daemon are separate processes over one document, so a cache would let the
/// daemon answer with destinations the operator had already renamed. A point
/// read on demand is not polling (the same distinction ``StatusSink`` draws) —
/// there is no timer here and nothing runs when no one is asking. The
/// consequence worth knowing: the ``EventBus`` change events below reach
/// **in-process** subscribers only; a cross-process observer stays correct by
/// reading, not by listening.
///
/// The directory is injectable so tests exercise real load/save round-trips
/// against a temporary directory, never the operator's own destinations.
public actor DestinationStore {
    /// The file name of the destinations document.
    public static let fileName = "destinations.json"

    /// The directory holding the destinations file.
    public let directoryURL: URL

    /// The destinations file's location.
    public let fileURL: URL

    /// The secret store each destination's stream key is filed in.
    private let secureStorage: any SecureStorage

    /// The bus the store's change events go out on.
    private let eventBus: EventBus

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - directory: The directory holding the destinations file (default:
    ///     `~/Library/Application Support/Tingra`, the established Tingra home
    ///     beside the project document and the daemon's socket).
    ///   - secureStorage: The secret store stream keys are filed in (default:
    ///     the Keychain, in the shared access group when the running binary
    ///     declares one).
    ///   - eventBus: The bus change events are emitted on.
    public init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "Tingra"),
        secureStorage: any SecureStorage = KeychainSecureStorage(
            accessGroup: KeychainSecureStorage.sharedAccessGroup()),
        eventBus: EventBus
    ) {
        self.directoryURL = directory
        self.fileURL = directory.appending(path: Self.fileName)
        self.secureStorage = secureStorage
        self.eventBus = eventBus
    }

    /// The secure-storage account a destination's stream key is filed under.
    ///
    /// Keyed by the destination's **id**, not its URL: two destinations can
    /// share an ingest URL with different keys, and editing a URL would orphan
    /// a key stored under the old one. The prefix keeps these items distinct
    /// from any other secret the host files.
    ///
    /// - Parameter id: The destination's stable id.
    /// - Returns: The account string.
    public static func secureStorageAccount(for id: DestinationID) -> String {
        "destination:\(id.rawValue)"
    }

    // MARK: - Reading

    /// The operator's saved destinations, in file order.
    ///
    /// A store with no file yet is empty, not an error — that is a fresh
    /// install, and the first ``add(_:)`` creates the file.
    ///
    /// - Returns: The saved destinations.
    /// - Throws: ``DestinationStoreError/unreadableStore(path:reason:)`` when
    ///   a file exists but does not decode.
    public func destinations() throws -> [StoredDestination] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        do {
            return try JSONDecoder().decode([StoredDestination].self, from: Data(contentsOf: fileURL))
        } catch {
            throw DestinationStoreError.unreadableStore(
                path: fileURL.path(percentEncoded: false), reason: String(describing: error))
        }
    }

    /// The saved destination with an id, or nil when none has it.
    ///
    /// - Parameter id: The destination id.
    /// - Returns: The destination, or nil.
    /// - Throws: ``DestinationStoreError/unreadableStore(path:reason:)``.
    public func destination(id: DestinationID) throws -> StoredDestination? {
        try destinations().first { $0.id == id }
    }

    /// Resolves a `destination` selector against the saved destinations,
    /// **mirroring input selection** (CLI.md, "Input selection") so an agent
    /// learns one rule for both:
    ///
    /// 1. **ID** — an exact match on a destination's stable id wins outright,
    ///    even if some other destination is *named* that id.
    /// 2. **Name** — anything else matches case-insensitively against names
    ///    (`localizedStandardContains`, so "twitch" finds "My Twitch") and
    ///    must match exactly one.
    ///
    /// There is deliberately no index form. A store index is not stable across
    /// an edit and never appears in an agent's context, where the name it was
    /// given ("my Twitch") is the whole point.
    ///
    /// - Parameter selector: The id or name selector.
    /// - Returns: The one destination it names.
    /// - Throws: ``DestinationStoreError/notFound(selector:)`` when nothing
    ///   matches, ``DestinationStoreError/ambiguous(selector:matches:)`` when
    ///   a name matches more than one, or
    ///   ``DestinationStoreError/unreadableStore(path:reason:)``.
    public func resolve(selector: String) throws -> StoredDestination {
        let candidates = try destinations()
        if let exact = candidates.first(where: { $0.id.rawValue == selector }) {
            return exact
        }
        let matches = candidates.filter { $0.name.localizedStandardContains(selector) }
        switch matches.count {
        case 0:
            throw DestinationStoreError.notFound(selector: selector)
        case 1:
            return matches[0]
        default:
            throw DestinationStoreError.ambiguous(selector: selector, matches: matches.map(\.name))
        }
    }

    // MARK: - Keys

    /// Whether a stream key is filed for a destination.
    ///
    /// **Reports `false` when the key cannot be read**, not an error, so a
    /// listing always answers. In an unsigned development build every key is
    /// unreadable (no entitlement, no access group), and the honest answer to
    /// "does this process have a key for it?" is no. The reason is not
    /// swallowed: an `error` event goes out on the bus naming the fix, and
    /// ``key(for:)`` throws
    /// ``DestinationStoreError/keyUnreadable(name:underlying:)`` if the
    /// destination is actually used to stream.
    ///
    /// - Parameter destination: The destination to check.
    /// - Returns: Whether a key is readable for it.
    public func hasKey(for destination: StoredDestination) -> Bool {
        do {
            return try secureStorage.secret(forAccount: Self.secureStorageAccount(for: destination.id)) != nil
        } catch {
            reportKeyUnreadable(destination, error)
            return false
        }
    }

    /// The stream key filed for a destination, or nil when it has none (a
    /// keyless destination is legal — some endpoints carry the key in the URL
    /// path, and local ingest often needs none).
    ///
    /// The returned key is a secret: it goes into a ``Destination`` and
    /// nowhere else — never an event param, a log line, a tool result, or an
    /// error message.
    ///
    /// - Parameter destination: The destination whose key to read.
    /// - Returns: The stream key, or nil when none is filed.
    /// - Throws: ``DestinationStoreError/keyUnreadable(name:underlying:)``
    ///   when the store rejects the read — the case an unsigned development
    ///   build hits, whose message names the fix.
    public func key(for destination: StoredDestination) throws -> String? {
        do {
            return try secureStorage.secret(forAccount: Self.secureStorageAccount(for: destination.id))
        } catch let error as SecureStorageError {
            reportKeyUnreadable(destination, error)
            throw DestinationStoreError.keyUnreadable(name: destination.name, underlying: error)
        }
    }

    /// Files (or clears) a destination's stream key.
    ///
    /// The operator's act, performed in the app — an agent never reaches this,
    /// because the point of the store is that keys stop transiting agent
    /// conversations (DESTINATIONS.md, "The tool surface").
    ///
    /// - Parameters:
    ///   - key: The stream key, or nil/empty to clear it (a keyless
    ///     destination).
    ///   - destination: The destination it belongs to.
    /// - Throws: ``SecureStorageError`` when the store rejects the write.
    public func setKey(_ key: String?, for destination: StoredDestination) throws {
        let account = Self.secureStorageAccount(for: destination.id)
        guard let key, !key.isEmpty else {
            try secureStorage.removeSecret(forAccount: account)
            return
        }
        try secureStorage.setSecret(key, forAccount: account)
    }

    // MARK: - Editing

    /// Adds a destination and emits `destination.added`.
    ///
    /// - Parameter destination: The destination to file.
    /// - Throws: ``DestinationStoreError/duplicateID(_:)`` when its id is
    ///   already saved, or an unreadable/unwritable store.
    public func add(_ destination: StoredDestination) throws {
        var all = try destinations()
        guard !all.contains(where: { $0.id == destination.id }) else {
            throw DestinationStoreError.duplicateID(destination.id)
        }
        all.append(destination)
        try write(all)
        emit("destination.added", destination)
    }

    /// Replaces a saved destination's name and URL, keeping its id — and
    /// therefore its filed key — and emits `destination.changed`.
    ///
    /// - Parameter destination: The destination in its edited form.
    /// - Throws: ``DestinationStoreError/notFound(selector:)`` when no saved
    ///   destination has that id, or a store read/write failure.
    public func update(_ destination: StoredDestination) throws {
        var all = try destinations()
        guard let index = all.firstIndex(where: { $0.id == destination.id }) else {
            throw DestinationStoreError.notFound(selector: destination.id.rawValue)
        }
        all[index] = destination
        try write(all)
        emit("destination.changed", destination)
    }

    /// Removes a saved destination **and its stored key**, then emits
    /// `destination.removed`.
    ///
    /// Deleting the record without the key would leave a secret at rest that
    /// nothing owns and nothing can reach — the same never-orphan-a-key rule
    /// the app's confirmed delete already follows.
    ///
    /// **The key goes first, and the order is the point.** Either step can
    /// fail, so one of two half-deletes is possible; this picks the recoverable
    /// one. Clearing the key first means a failed record write leaves a saved
    /// destination that has merely lost its key — visible, re-enterable, and
    /// fixed by retrying the delete (both steps are idempotent). Writing the
    /// record first would mean a failed key clear leaves a secret at rest that
    /// no record points at and no surface can reach again.
    ///
    /// - Parameter id: The destination to remove. Removing one that is not
    ///   saved is not an error.
    /// - Throws: A ``SecureStorageError`` when the key cannot be cleared, or a
    ///   store read/write failure.
    public func remove(id: DestinationID) throws {
        var all = try destinations()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let removed = all.remove(at: index)
        try secureStorage.removeSecret(forAccount: Self.secureStorageAccount(for: id))
        try write(all)
        emit("destination.removed", removed)
    }

    // MARK: - Private

    /// Writes the destinations document atomically, creating the directory if
    /// needed.
    ///
    /// - Parameter destinations: The full list to save.
    /// - Throws: ``DestinationStoreError/unwritableStore(path:reason:)``.
    private func write(_ destinations: [StoredDestination]) throws {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(destinations).write(to: fileURL, options: [.atomic])
        } catch {
            throw DestinationStoreError.unwritableStore(
                path: fileURL.path(percentEncoded: false), reason: String(describing: error))
        }
    }

    /// Emits one change event. The params are the record — id, name, URL —
    /// none of which is a secret; the key is never among them.
    ///
    /// - Parameters:
    ///   - name: The event name (`destination.added`/`.changed`/`.removed`).
    ///   - destination: The destination the change concerns.
    private func emit(_ name: String, _ destination: StoredDestination) {
        eventBus.event(
            name,
            domain: .platform,
            params: [
                "id": .string(destination.id.rawValue),
                "name": .string(destination.name),
                "url": .string(destination.url.absoluteString),
            ]
        )
    }

    /// Reports an unreadable key as an `error` event, so the reason a listing
    /// says `hasKey: false` is visible rather than inferred.
    ///
    /// - Parameters:
    ///   - destination: The destination whose key could not be read.
    ///   - error: The underlying secure-storage failure.
    private func reportKeyUnreadable(_ destination: StoredDestination, _ error: any Error) {
        // Prefer the store's own wording, which names the unsigned-build fix;
        // an error from some other seam is reported as it describes itself.
        let message =
            (error as? SecureStorageError)
            .map { String(describing: DestinationStoreError.keyUnreadable(name: destination.name, underlying: $0)) }
            ?? String(describing: error)
        eventBus.error(
            "destination.keyUnreadable",
            domain: .platform,
            params: [
                "identifier": .string(ErrorIdentifier.pipelineError.rawValue),
                "id": .string(destination.id.rawValue),
                "message": .string(message),
            ]
        )
    }
}
