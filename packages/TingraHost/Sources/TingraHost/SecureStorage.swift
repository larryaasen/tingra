//
//  SecureStorage.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Security

/// The host's secret store: hardware-backed, Keychain-first storage for
/// stream keys and any other sensitive value (CLAUDE.md, "Error Handling":
/// secrets live only in the host's Keychain-backed secure storage, never in
/// plaintext config, events, or logs).
///
/// A protocol seam so the same callers (the app storing a stream key, the
/// daemon later) run against the real Keychain in production and an
/// in-memory double in tests — no Keychain access, no unlocked login
/// keychain, and no prompt on a CI runner.
///
/// Secrets are addressed by an opaque `account` string (the destination URL,
/// for a stream key); the store can say which accounts it holds — never what
/// they hold — and never returns a secret through an event or a log: reads
/// and writes are the only way in and out.
public protocol SecureStorage: Sendable {
    /// Stores (or replaces) the secret for the given account.
    ///
    /// - Parameters:
    ///   - secret: The sensitive value to store; never logged or emitted.
    ///   - account: The opaque key the secret is stored under.
    /// - Throws: ``SecureStorageError`` if the store rejects the write.
    func setSecret(_ secret: String, forAccount account: String) throws

    /// Reads the secret stored for the given account, or `nil` when none is
    /// stored.
    ///
    /// - Parameter account: The opaque key the secret was stored under.
    /// - Returns: The stored secret, or `nil` if the account has none.
    /// - Throws: ``SecureStorageError`` if the store rejects the read (a
    ///   missing account is not an error — it returns `nil`).
    func secret(forAccount account: String) throws -> String?

    /// Removes the secret stored for the given account. Removing an account
    /// that holds no secret is not an error.
    ///
    /// - Parameter account: The opaque key to clear.
    /// - Throws: ``SecureStorageError`` if the store rejects the delete.
    func removeSecret(forAccount account: String) throws

    /// The accounts that currently hold a secret — the keys, never the
    /// values — so a caller can count what is stored or clear it item by
    /// item. An empty store returns an empty list.
    ///
    /// - Returns: The accounts holding a secret, in a stable order.
    /// - Throws: ``SecureStorageError`` if the store rejects the read.
    func accounts() throws -> [String]

    /// Removes every secret the store holds — the whole of Tingra's items,
    /// nothing of any other app's. Clearing an empty store is not an error.
    ///
    /// The app's remove-all-data action uses this rather than removing
    /// account by account, so a secret whose destination is gone from every
    /// document (an orphan) is cleared with the rest.
    ///
    /// - Throws: ``SecureStorageError`` if the store rejects the delete.
    func removeAllSecrets() throws
}

/// A failure from ``SecureStorage``. Recoverable and developer-facing — the
/// engine never crashes over a Keychain hiccup (CLAUDE.md, never-crash rule);
/// a store or read failure surfaces so the caller can fall back to the
/// in-memory secret it already holds.
public enum SecureStorageError: Error, Equatable, CustomStringConvertible {
    /// The Keychain returned a status other than success or "not found". The
    /// raw `OSStatus` is developer-facing only (it names no secret).
    case keychain(OSStatus)

    /// A stored value could not be read back as UTF-8 text — a corrupt or
    /// foreign item under the same account.
    case malformedSecret

    /// A developer-facing description; carries no secret value.
    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "The secure store rejected the operation (OSStatus \(status): \(message))."
        case .malformedSecret:
            return "The stored secret could not be read back as text; it may have been written by another app."
        }
    }
}

/// The production ``SecureStorage``: the login Keychain, storing each secret
/// as a generic-password item keyed by the account under one service.
///
/// A value type with no mutable state, so it is trivially `Sendable`; every
/// call is a synchronous Security-framework request. Nothing here logs or
/// emits — the secret enters and leaves only through the item's data.
public struct KeychainSecureStorage: SecureStorage {
    /// The Keychain service every item is filed under — Tingra's bundle
    /// identifier namespace, so its items are distinct from any other app's.
    private let service: String

    /// The keychain access group items are filed in and read from, or nil to
    /// use the process's default group.
    ///
    /// Data-protection keychain items are partitioned by access group, and the
    /// app and `tingra-cli` are different signed binaries — so without a
    /// shared group an item filed by one is invisible to the other. Passing
    /// ``sharedAccessGroup()`` here joins the group when the running binary
    /// declares one (DESTINATIONS.md, "Key sharing between the app and the
    /// daemon").
    ///
    /// The app declares one again as of 2026-08-30; `tingra-cli` cannot and
    /// passes nil. `keychain-access-groups` is a restricted entitlement: the
    /// kernel authorizes it from an embedded provisioning profile, which only
    /// a bundle's **main executable** can carry — v0.1.1 shipped it on the
    /// bare CLI and was SIGKILLed at every launch, and a bare helper placed
    /// inside a provisioned bundle is killed the same way (measured
    /// 2026-08-30; DESTINATIONS.md, "What the probe measured"). So the daemon
    /// joins this group only by becoming a bundle of its own, which is
    /// packaging work sequenced with the app cask.
    private let accessGroup: String?

    /// Creates a Keychain-backed store.
    ///
    /// - Parameters:
    ///   - service: The Keychain service string (default
    ///     `"com.moonwink.tingra"`, Tingra's identifier namespace).
    ///   - accessGroup: The keychain access group to file items in (default
    ///     nil: the process's default group). Pass ``sharedAccessGroup()`` to
    ///     use the group both Tingra binaries declare.
    public init(service: String = "com.moonwink.tingra", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The suffix of the shared keychain access group, as written in the app's
    /// `keychain-access-groups` entitlement:
    /// `$(TeamIdentifierPrefix)com.moonwink.tingra.shared`.
    ///
    /// `tingra-cli` declared the same group until 0.1.2 and no longer can —
    /// see ``sharedAccessGroup()``.
    ///
    /// The group's **prefix** is deliberately not written here either, and for
    /// a second reason beyond secrecy: the app's entitlement carries
    /// `$(AppIdentifierPrefix)`, which on an older Apple account is not the
    /// team identifier at all (it is the legacy App ID prefix, and Tingra's
    /// two differ). Matching on the suffix is what keeps this code correct
    /// under either.
    ///
    /// Only the suffix is a constant. The full group string carries the team
    /// identifier prefix, which a public repository must never hold in a
    /// tracked file (CLAUDE.md, "Signing") — hence ``sharedAccessGroup()``,
    /// which reads the already-expanded value out of the running binary.
    public static let sharedAccessGroupSuffix = "com.moonwink.tingra.shared"

    /// The team-prefixed shared keychain access group of the **running**
    /// binary, or nil when it has none.
    ///
    /// The signing process expands `$(TeamIdentifierPrefix)` into the
    /// entitlement it embeds, so the signed binary already carries the one
    /// value this needs — reading it back is how the group is known at runtime
    /// without a Team ID ever appearing in source.
    ///
    /// Returns nil whenever the running binary declares no such group: every
    /// `tingra-cli` build (unsigned `swift build` and signed release alike,
    /// since the entitlement had to be removed to keep the binary launchable)
    /// and every unsigned build of the app. That is a real state, not an
    /// error: the caller degrades honestly — names and URLs still resolve, and
    /// a key the process cannot read is reported as absent with a structured
    /// error explaining why (see ``DestinationStore``).
    ///
    /// Note that nil is not the only way a process ends up without the
    /// data-protection keychain, and the difference matters when reading a
    /// failure: a binary with **no keychain group at all** does not merely
    /// miss this group, it cannot use the data-protection keychain — writes
    /// return `errSecMissingEntitlement` (−34018) and reads see an empty
    /// group. See ``baseQuery(forAccount:)``.
    ///
    /// - Returns: The full access group string, or nil when the binary
    ///   declares none.
    public static func sharedAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
        guard let groups = value as? [String] else { return nil }
        return groups.first { $0.hasSuffix(sharedAccessGroupSuffix) }
    }

    /// The base query identifying one account's generic-password item.
    ///
    /// Uses the data-protection keychain (`kSecUseDataProtectionKeychain`) —
    /// Apple's recommended store for new macOS code, and the one that honors
    /// the `kSecAttrAccessible` accessibility attribute (the legacy file-based
    /// login keychain ignores it). It keys items to the app's own identity, so
    /// reads and writes need no user unlock prompt.
    ///
    /// **It has a precondition worth stating, because failing it is silent:**
    /// the running binary must carry a keychain access group, which it gets
    /// from a provisioning profile (either `keychain-access-groups` or the
    /// `com.apple.application-identifier` every provisioned bundle carries).
    /// A binary with neither — any bare executable, and any app bundle signed
    /// without a profile — gets `errSecMissingEntitlement` (−34018) on write
    /// and an empty group on read, measured across both signing identities
    /// and both launch paths on 2026-08-30. The app carried exactly that shape
    /// from its conversion to an Xcode project until this was fixed, so every
    /// stream key it filed was rejected and reported as a `securestore.write`
    /// error while the session carried on with the key in memory.
    private func baseQuery(forAccount account: String) -> [CFString: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount] = account
        return query
    }

    /// The query matching **every** generic-password item Tingra filed: the
    /// service, the data-protection keychain, and the access group when there
    /// is one — ``baseQuery(forAccount:)`` narrowed to nothing. Never matches
    /// another app's items, because the service is Tingra's own namespace.
    private func serviceQuery() -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecUseDataProtectionKeychain: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    /// Stores the secret by clearing any existing item for the account and
    /// adding the new one — idempotent, so re-storing a key overwrites rather
    /// than duplicates.
    public func setSecret(_ secret: String, forAccount account: String) throws {
        try removeSecret(forAccount: account)
        var query = baseQuery(forAccount: account)
        query[kSecValueData] = Data(secret.utf8)
        // Readable only after the device is first unlocked, and never synced
        // off-device: a stream key is machine-local, not iCloud material.
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureStorageError.keychain(status) }
    }

    /// Reads the account's secret, returning `nil` for a missing item and
    /// throwing only on a genuine Keychain error or a non-UTF-8 value.
    public func secret(forAccount account: String) throws -> String? {
        var query = baseQuery(forAccount: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureStorageError.keychain(status) }
        guard let data = item as? Data else { throw SecureStorageError.malformedSecret }
        guard let secret = String(data: data, encoding: .utf8) else { throw SecureStorageError.malformedSecret }
        return secret
    }

    /// Deletes the account's item, treating "not found" as success so a
    /// clear is idempotent.
    public func removeSecret(forAccount account: String) throws {
        let status = SecItemDelete(baseQuery(forAccount: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStorageError.keychain(status)
        }
    }

    /// Lists the accounts of every item under Tingra's service, reading the
    /// items' attributes only — `kSecReturnData` is deliberately absent, so
    /// no secret leaves the Keychain on this path. A binary the
    /// data-protection keychain refuses sees an empty group here rather than
    /// an error (see ``baseQuery(forAccount:)``).
    public func accounts() throws -> [String] {
        var query = serviceQuery()
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw SecureStorageError.keychain(status) }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// Deletes every item under Tingra's service in one call, treating "not
    /// found" as success so clearing an empty store is idempotent.
    public func removeAllSecrets() throws {
        let status = SecItemDelete(serviceQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStorageError.keychain(status)
        }
    }
}
