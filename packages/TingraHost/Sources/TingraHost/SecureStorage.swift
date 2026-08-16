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
/// for a stream key); the store keeps no index of accounts and never returns
/// a secret through an event or a log — reads and writes are the only way in
/// and out.
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
    /// As of 0.1.2 no shipped binary declares one, so this is nil in practice
    /// and the two processes do not share keys. `keychain-access-groups` is a
    /// restricted entitlement: the kernel authorizes it from an embedded
    /// provisioning profile, which the bare `tingra-cli` executable cannot
    /// carry — v0.1.1 shipped it and was SIGKILLed at every launch. The seam
    /// stays because the mechanism is right and only the CLI's packaging is
    /// wrong; DESTINATIONS.md owns the replacement.
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
    /// Returns nil whenever the running binary declares no such group, which
    /// as of 0.1.2 is every build of both products. In `tingra-cli` — unsigned
    /// `swift build` (no entitlements at all) and signed release alike — the
    /// entitlement had to be removed to keep the binary launchable; in the app
    /// it was removed once the CLI could no longer join, leaving nothing to
    /// share with. That is a real state, not an error: the caller degrades
    /// honestly — names and URLs
    /// still resolve, and a key the process cannot read is reported as absent
    /// with a structured error explaining why (see ``DestinationStore``).
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
    private func baseQuery(forAccount account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
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
}
