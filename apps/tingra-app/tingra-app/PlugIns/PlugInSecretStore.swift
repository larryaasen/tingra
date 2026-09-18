//
//  PlugInSecretStore.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-17.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost
import TingraPlugInKit

/// The secrets of app-tier plug-ins — a chat service's token, a password —
/// each an item in the app's Keychain-backed secure storage, the same store
/// the stream keys live in (PLUGINS.md, Decision 7: secrets are never a
/// storage scope; the narrowed method built 2026-09-17).
///
/// **Narrowed by account.** A plug-in's secret is filed under
/// `plugin:<PlugInID>.<name>`, and the plug-in id is the connection's, never
/// a parameter, so a plug-in reads and writes its own secrets and no
/// other's — and never a stream key, whose items carry the
/// `destination:` prefix `DestinationStore` gives them. The `plugin:` prefix
/// is what lets the Data settings pane count and clear plug-in secrets apart
/// from the keys.
///
/// The value enters and leaves through the store's reads and writes alone:
/// nothing here emits, logs, or files it anywhere else.
struct PlugInSecretStore: Sendable {
    /// The secure storage the items live in — the engine's own, so a plug-in
    /// secret is filed in the same keychain access group as a stream key.
    let secureStorage: any SecureStorage

    /// The prefix every plug-in secret's account carries, keeping the items
    /// distinct from the stream keys' and from any other secret the host
    /// files later.
    static let accountPrefix = "plugin:"

    /// Creates a store over the app's secure storage.
    ///
    /// - Parameter secureStorage: The secure storage the items live in.
    init(secureStorage: any SecureStorage) {
        self.secureStorage = secureStorage
    }

    /// The secure-storage account a plug-in's secret is filed under:
    /// `plugin:<PlugInID>.<name>` — the plug-in's namespace, the way a pane
    /// id is `<plugInID>.<name>`.
    ///
    /// - Parameters:
    ///   - name: The secret's name within the plug-in.
    ///   - plugIn: The plug-in the secret belongs to.
    /// - Returns: The account string.
    static func account(named name: String, for plugIn: PlugInID) -> String {
        "\(accountPrefix)\(plugIn.rawValue).\(name)"
    }

    /// Whether an account is a plug-in secret's, by its prefix — how the
    /// Data settings pane tells plug-in secrets from stream keys in one
    /// listing.
    ///
    /// - Parameter account: The account string.
    /// - Returns: True for a plug-in secret's account.
    static func isPlugInAccount(_ account: String) -> Bool {
        account.hasPrefix(accountPrefix)
    }

    /// One of a plug-in's secrets, or nil when none is stored under that
    /// name.
    ///
    /// - Parameters:
    ///   - name: The secret's name within the plug-in.
    ///   - plugIn: The plug-in the secret belongs to.
    /// - Returns: The secret, or nil.
    /// - Throws: `SecureStorageError` when the store refuses the read.
    func secret(named name: String, for plugIn: PlugInID) throws -> String? {
        try secureStorage.secret(forAccount: Self.account(named: name, for: plugIn))
    }

    /// Stores one of a plug-in's secrets, replacing any stored under that
    /// name; nil removes it.
    ///
    /// - Parameters:
    ///   - secret: The secret to store, or nil to remove the stored one.
    ///   - name: The secret's name within the plug-in.
    ///   - plugIn: The plug-in the secret belongs to.
    /// - Throws: `SecureStorageError` when the store refuses the write.
    func setSecret(_ secret: String?, named name: String, for plugIn: PlugInID) throws {
        let account = Self.account(named: name, for: plugIn)
        guard let secret else {
            try secureStorage.removeSecret(forAccount: account)
            return
        }
        try secureStorage.setSecret(secret, forAccount: account)
    }

    /// The accounts of every plug-in secret in the store — the accounts,
    /// never the values — so the Data settings pane can count them.
    ///
    /// - Returns: The plug-in secrets' accounts, in the store's order.
    /// - Throws: `SecureStorageError` when the store refuses the read.
    func accounts() throws -> [String] {
        try secureStorage.accounts().filter(Self.isPlugInAccount)
    }

    /// Removes every plug-in secret, one account at a time, and no stream
    /// key. Removing from a store that holds none is not an error.
    ///
    /// - Throws: `SecureStorageError` when the store refuses the read or a
    ///   delete.
    func removeAll() throws {
        for account in try accounts() {
            try secureStorage.removeSecret(forAccount: account)
        }
    }
}
