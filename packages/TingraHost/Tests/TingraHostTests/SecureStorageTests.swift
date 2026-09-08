//
//  SecureStorageTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraHost

// The in-memory double these tests run against is shared with the
// ``DestinationStore`` suite; it lives in SecureStorageTestSupport.swift.

@Suite("SecureStorage")
struct SecureStorageTests {
    @Test("A stored secret reads back for its account")
    func storesAndReads() throws {
        let storage = InMemorySecureStorage()
        try storage.setSecret("live_abc123", forAccount: "rtmp://live.example/app")
        #expect(try storage.secret(forAccount: "rtmp://live.example/app") == "live_abc123")
    }

    @Test("Reading an account that holds no secret returns nil")
    func missingReadsNil() throws {
        let storage = InMemorySecureStorage()
        #expect(try storage.secret(forAccount: "rtmp://live.example/app") == nil)
    }

    @Test("Storing a secret again replaces the previous value")
    func overwriteReplaces() throws {
        let storage = InMemorySecureStorage()
        try storage.setSecret("first", forAccount: "acct")
        try storage.setSecret("second", forAccount: "acct")
        #expect(try storage.secret(forAccount: "acct") == "second")
    }

    @Test("Removing a secret clears it, and removing again is not an error")
    func removeIsIdempotent() throws {
        let storage = InMemorySecureStorage()
        try storage.setSecret("value", forAccount: "acct")
        try storage.removeSecret(forAccount: "acct")
        #expect(try storage.secret(forAccount: "acct") == nil)
        // A second remove of the now-empty account must not throw.
        try storage.removeSecret(forAccount: "acct")
        #expect(try storage.secret(forAccount: "acct") == nil)
    }

    @Test("Secrets are isolated per account")
    func accountsAreIsolated() throws {
        let storage = InMemorySecureStorage()
        try storage.setSecret("key-a", forAccount: "a")
        try storage.setSecret("key-b", forAccount: "b")
        #expect(try storage.secret(forAccount: "a") == "key-a")
        #expect(try storage.secret(forAccount: "b") == "key-b")
    }

    @Test("The accounts listing names every account holding a secret, and never a value")
    func accountsListsKeysOnly() throws {
        let storage = InMemorySecureStorage()
        #expect(try storage.accounts().isEmpty)
        try storage.setSecret("key-b", forAccount: "b")
        try storage.setSecret("key-a", forAccount: "a")
        let accounts = try storage.accounts()
        #expect(accounts == ["a", "b"])
        #expect(!accounts.contains("key-a"))
        #expect(!accounts.contains("key-b"))
    }

    @Test("Removing every secret empties the store, and clearing an empty store is not an error")
    func removeAllClearsEveryAccount() throws {
        let storage = InMemorySecureStorage()
        try storage.setSecret("key-a", forAccount: "a")
        try storage.setSecret("key-b", forAccount: "b")
        try storage.removeAllSecrets()
        #expect(try storage.accounts().isEmpty)
        #expect(try storage.secret(forAccount: "a") == nil)
        // Clearing again finds nothing, and that is not a failure.
        try storage.removeAllSecrets()
        #expect(try storage.accounts().isEmpty)
    }

    @Test("Listing accounts on a store that refuses reads returns the read error rather than an empty list")
    func accountsListingSurfacesReadError() throws {
        let storage = InMemorySecureStorage(readFailure: .keychain(-34018))
        #expect(throws: SecureStorageError.keychain(-34018)) {
            try storage.accounts()
        }
    }

    @Test("The Keychain store lists no accounts in a build the data-protection keychain refuses, rather than trapping")
    func keychainAccountsInUnentitledBuild() throws {
        // An unsigned test process has no keychain access group, so the
        // data-protection keychain shows it an empty group on read; whatever
        // the status, the call must return or throw a structured error, and
        // never a secret.
        let storage = KeychainSecureStorage(service: "com.moonwink.tingra.tests.\(UUID().uuidString)")
        do {
            let accounts = try storage.accounts()
            #expect(accounts.isEmpty)
        } catch let error as SecureStorageError {
            guard case .keychain = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test("The shared access group is nil in a build that declares none, rather than trapping")
    func sharedAccessGroupWithoutEntitlement() {
        // This test binary is ad-hoc signed with no entitlements, which is
        // exactly the unsigned-development-build shape: reading the group back
        // out of the running code must answer "none" and never trap
        // (DESTINATIONS.md, "Key sharing between the app and the daemon").
        #expect(KeychainSecureStorage.sharedAccessGroup() == nil)
    }

    @Test("The shared access group suffix is the value both entitlements declare")
    func sharedAccessGroupSuffix() {
        // Only the suffix is a constant; the team prefix is never in source.
        #expect(KeychainSecureStorage.sharedAccessGroupSuffix == "com.moonwink.tingra.shared")
    }
}
