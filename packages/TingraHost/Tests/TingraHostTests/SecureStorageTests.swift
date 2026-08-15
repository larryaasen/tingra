//
//  SecureStorageTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

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
