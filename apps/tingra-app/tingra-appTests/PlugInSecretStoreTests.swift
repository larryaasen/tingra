//
//  PlugInSecretStoreTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-17.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraHost
import TingraPlugInKit

@testable import TingraApp

/// The plug-ins' secret store over the app's secure storage: accounts in
/// the plug-in's own namespace, a round trip, and a clear that leaves the
/// stream keys alone.
@Suite("PlugInSecretStore")
struct PlugInSecretStoreTests {
    /// The Notes plug-in's id.
    private let notes = PlugInID(rawValue: "com.moonwink.tingra.notes")

    /// A second plug-in.
    private let other = PlugInID(rawValue: "com.example.tally")

    @Test("an account is the plug-in prefix, the plug-in id, and the name")
    func accountNaming() {
        #expect(PlugInSecretStore.account(named: "token", for: notes) == "plugin:com.moonwink.tingra.notes.token")
        #expect(PlugInSecretStore.isPlugInAccount("plugin:com.moonwink.tingra.notes.token"))
        #expect(!PlugInSecretStore.isPlugInAccount("destination:8B1C"))
        #expect(!PlugInSecretStore.isPlugInAccount("com.moonwink.tingra.notes.token"))
    }

    @Test("a secret round-trips under its plug-in and name, and nil removes it")
    func roundTrip() throws {
        let secureStorage = InMemorySecureStorage()
        let store = PlugInSecretStore(secureStorage: secureStorage)
        #expect(try store.secret(named: "token", for: notes) == nil)
        try store.setSecret("live_abc", named: "token", for: notes)
        #expect(try store.secret(named: "token", for: notes) == "live_abc")
        #expect(try secureStorage.secret(forAccount: "plugin:com.moonwink.tingra.notes.token") == "live_abc")
        try store.setSecret("live_def", named: "token", for: notes)
        #expect(try store.secret(named: "token", for: notes) == "live_def")
        try store.setSecret(nil, named: "token", for: notes)
        #expect(try store.secret(named: "token", for: notes) == nil)
        try store.setSecret(nil, named: "token", for: notes)
    }

    @Test("two plug-ins' secrets of the same name are separate items")
    func plugInsAreSeparate() throws {
        let store = PlugInSecretStore(secureStorage: InMemorySecureStorage())
        try store.setSecret("notes-token", named: "token", for: notes)
        try store.setSecret("tally-token", named: "token", for: other)
        #expect(try store.secret(named: "token", for: notes) == "notes-token")
        #expect(try store.secret(named: "token", for: other) == "tally-token")
        #expect(
            try store.accounts() == ["plugin:com.example.tally.token", "plugin:com.moonwink.tingra.notes.token"])
    }

    @Test("accounts and remove all cover the plug-ins' items and never a stream key")
    func removeAllLeavesStreamKeys() throws {
        let secureStorage = InMemorySecureStorage()
        let store = PlugInSecretStore(secureStorage: secureStorage)
        try secureStorage.setSecret("live_key", forAccount: "destination:8B1C")
        try store.setSecret("notes-token", named: "token", for: notes)
        try store.setSecret("tally-token", named: "token", for: other)
        #expect(try store.accounts().count == 2)
        try store.removeAll()
        #expect(try store.accounts().isEmpty)
        #expect(try secureStorage.accounts() == ["destination:8B1C"])
        try store.removeAll()
    }
}
