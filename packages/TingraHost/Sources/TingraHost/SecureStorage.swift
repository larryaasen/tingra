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

    /// Creates a Keychain-backed store.
    ///
    /// - Parameter service: The Keychain service string (default
    ///   `"com.moonwink.tingra"`, Tingra's identifier namespace).
    public init(service: String = "com.moonwink.tingra") {
        self.service = service
    }

    /// The base query identifying one account's generic-password item.
    ///
    /// Uses the data-protection keychain (`kSecUseDataProtectionKeychain`) —
    /// Apple's recommended store for new macOS code, and the one that honors
    /// the `kSecAttrAccessible` accessibility attribute (the legacy file-based
    /// login keychain ignores it). It keys items to the app's own identity, so
    /// reads and writes need no user unlock prompt.
    private func baseQuery(forAccount account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
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
