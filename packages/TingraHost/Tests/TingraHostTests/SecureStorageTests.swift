//
//  SecureStorageTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization
import Testing

@testable import TingraHost

/// An in-memory ``SecureStorage`` double, so the seam's contract is exercised
/// without touching the real Keychain — no unlocked login keychain and no
/// prompt on a CI runner (``KeychainSecureStorage`` is validated by hand). It
/// implements the same documented semantics the app depends on: a store
/// overwrites, a read of a missing account is `nil`, and a remove is
/// idempotent.
private final class InMemorySecureStorage: SecureStorage {
    /// The stored secrets, keyed by account.
    private let secrets = Mutex<[String: String]>([:])

    func setSecret(_ secret: String, forAccount account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    func secret(forAccount account: String) throws -> String? {
        secrets.withLock { $0[account] }
    }

    func removeSecret(forAccount account: String) throws {
        secrets.withLock { $0[account] = nil }
    }
}

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
}
