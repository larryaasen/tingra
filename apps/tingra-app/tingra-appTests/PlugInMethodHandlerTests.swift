//
//  PlugInMethodHandlerTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraAppPlugInKit
import TingraEventBus
import TingraHost
import TingraJSONRPC
import TingraPlugInKit

@testable import TingraApp

/// An in-memory plug-in store, keyed by scope and plug-in, with secrets
/// keyed by plug-in and name, and a switch that makes the secret store
/// refuse — the stand-in for a Keychain that rejects the binary.
private final class MemoryStore: PlugInStoring {
    /// The values.
    let values = Mutex<[String: JSONValue]>([:])

    /// The secrets.
    let secrets = Mutex<[String: String]>([:])

    /// The error every secret read and write throws, or nil.
    let secretFailure: SecureStorageError?

    /// Creates a store.
    ///
    /// - Parameter secretFailure: An error every secret call throws, or nil.
    init(secretFailure: SecureStorageError? = nil) {
        self.secretFailure = secretFailure
    }

    func value(scope: StorageScope, plugIn: PlugInID) async -> JSONValue? {
        values.withLock { $0["\(scope.rawValue):\(plugIn.rawValue)"] }
    }

    func setValue(_ value: JSONValue?, scope: StorageScope, plugIn: PlugInID) async {
        values.withLock { $0["\(scope.rawValue):\(plugIn.rawValue)"] = value }
    }

    func secret(named name: String, plugIn: PlugInID) async throws -> String? {
        if let secretFailure { throw secretFailure }
        return secrets.withLock { $0["\(plugIn.rawValue).\(name)"] }
    }

    func setSecret(_ secret: String?, named name: String, plugIn: PlugInID) async throws {
        if let secretFailure { throw secretFailure }
        secrets.withLock { $0["\(plugIn.rawValue).\(name)"] = secret }
    }
}

/// The app's `tingra/*` method handler: storage by scope under the
/// connection's own plug-in, events landed under the plug-in's domain, and
/// the app-scoped file store behind it.
@Suite("PlugInMethodHandler")
struct PlugInMethodHandlerTests {
    /// The Notes plug-in's id.
    private let notes = PlugInID(rawValue: "com.moonwink.tingra.notes")

    @Test("storage.get answers null before a set, then the set value, and nil clears")
    func storageRoundTrip() async throws {
        let store = MemoryStore()
        let handler = PlugInMethodHandler(plugIn: notes, eventBus: EventBus(), storage: store)
        let empty = try await handler.respond(method: AppTierMethod.storageGet, params: .object(["scope": "project"]))
        #expect(empty?["value"] == .null)
        let set = try await handler.respond(
            method: AppTierMethod.storageSet, params: .object(["scope": "project", "value": .object(["text": "hi"])]))
        #expect(set == .object([:]))
        let read = try await handler.respond(method: AppTierMethod.storageGet, params: .object(["scope": "project"]))
        #expect(read?["value"]?["text"] == .string("hi"))
        #expect(store.values.withLock { $0["project:com.moonwink.tingra.notes"] }?["text"] == .string("hi"))
        _ = try await handler.respond(
            method: AppTierMethod.storageSet, params: .object(["scope": "project", "value": .null]))
        let cleared = try await handler.respond(method: AppTierMethod.storageGet, params: .object(["scope": "project"]))
        #expect(cleared?["value"] == .null)
    }

    @Test("the two scopes are separate")
    func scopesAreSeparate() async throws {
        let handler = PlugInMethodHandler(plugIn: notes, eventBus: EventBus(), storage: MemoryStore())
        _ = try await handler.respond(
            method: AppTierMethod.storageSet, params: .object(["scope": "application", "value": .int(14)]))
        let project = try await handler.respond(method: AppTierMethod.storageGet, params: .object(["scope": "project"]))
        let application = try await handler.respond(
            method: AppTierMethod.storageGet, params: .object(["scope": "application"]))
        #expect(project?["value"] == .null)
        #expect(application?["value"] == .int(14))
    }

    @Test("a missing or unknown scope throws an invalid-params error naming the scopes")
    func badScopeThrows() async {
        let handler = PlugInMethodHandler(plugIn: notes, eventBus: EventBus(), storage: MemoryStore())
        await #expect(throws: JSONRPCError.self) {
            try await handler.respond(method: AppTierMethod.storageGet, params: .object(["scope": "secret"]))
        }
        await #expect(throws: JSONRPCError.self) {
            try await handler.respond(method: AppTierMethod.storageSet, params: nil)
        }
    }

    @Test("secrets.get answers null before a set, then the secret, and null removes it")
    func secretRoundTrip() async throws {
        let store = MemoryStore()
        let handler = PlugInMethodHandler(plugIn: notes, eventBus: EventBus(), storage: store)
        let empty = try await handler.respond(method: AppTierMethod.secretsGet, params: .object(["name": "token"]))
        #expect(empty?["value"] == .null)
        let set = try await handler.respond(
            method: AppTierMethod.secretsSet, params: .object(["name": "token", "value": "live_abc"]))
        #expect(set == .object([:]))
        let read = try await handler.respond(method: AppTierMethod.secretsGet, params: .object(["name": "token"]))
        #expect(read?["value"] == .string("live_abc"))
        #expect(store.secrets.withLock { $0["com.moonwink.tingra.notes.token"] } == "live_abc")
        _ = try await handler.respond(
            method: AppTierMethod.secretsSet, params: .object(["name": "token", "value": .null]))
        let removed = try await handler.respond(method: AppTierMethod.secretsGet, params: .object(["name": "token"]))
        #expect(removed?["value"] == .null)
        #expect(store.secrets.withLock { $0.isEmpty })
    }

    @Test("a secret is filed under the connection's plug-in, so another plug-in's handler cannot read it")
    func secretsAreNarrowedToThePlugIn() async throws {
        let store = MemoryStore()
        let bus = EventBus()
        let notesHandler = PlugInMethodHandler(plugIn: notes, eventBus: bus, storage: store)
        let otherHandler = PlugInMethodHandler(
            plugIn: PlugInID(rawValue: "com.example.tally"), eventBus: bus, storage: store)
        _ = try await notesHandler.respond(
            method: AppTierMethod.secretsSet, params: .object(["name": "token", "value": "notes-token"]))
        let other = try await otherHandler.respond(
            method: AppTierMethod.secretsGet, params: .object(["name": "token"]))
        #expect(other?["value"] == .null)
        let own = try await notesHandler.respond(method: AppTierMethod.secretsGet, params: .object(["name": "token"]))
        #expect(own?["value"] == .string("notes-token"))
    }

    @Test("a missing or empty name, or a value that is not a string, throws an invalid-params error")
    func badSecretParamsThrow() async {
        let handler = PlugInMethodHandler(plugIn: notes, eventBus: EventBus(), storage: MemoryStore())
        for params: JSONValue? in [nil, .object([:]), .object(["name": ""]), .object(["name": .int(3)])] {
            do {
                _ = try await handler.respond(method: AppTierMethod.secretsGet, params: params)
                Issue.record("expected an error for \(String(describing: params))")
            } catch let error as JSONRPCError {
                #expect(error.code == JSONRPCErrorCode.invalidParams.rawValue)
            } catch {
                Issue.record("expected a JSON-RPC error, got \(error)")
            }
        }
        do {
            _ = try await handler.respond(
                method: AppTierMethod.secretsSet, params: .object(["name": "token", "value": .int(42)]))
            Issue.record("expected an error for a non-string value")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.invalidParams.rawValue)
        } catch {
            Issue.record("expected a JSON-RPC error, got \(error)")
        }
    }

    @Test("a refused store answers an internal error and reports plugin.secrets, neither carrying the value")
    func refusedSecretIsReported() async throws {
        let bus = EventBus()
        let handler = PlugInMethodHandler(
            plugIn: notes, eventBus: bus, storage: MemoryStore(secretFailure: .keychain(-34018)))
        let events = bus.events()
        do {
            _ = try await handler.respond(
                method: AppTierMethod.secretsSet, params: .object(["name": "token", "value": "live_abc"]))
            Issue.record("expected the store's refusal to throw")
        } catch let error as JSONRPCError {
            #expect(error.code == JSONRPCErrorCode.internalError.rawValue)
            #expect(error.message.contains("write"))
            #expect(error.message.contains("token"))
            #expect(error.message.contains("-34018"))
            #expect(!error.message.contains("live_abc"))
        }
        bus.shutdown()
        var received: [EventBusEvent] = []
        for await event in events { received.append(event) }
        let reported = try #require(received.first { $0.name == "plugin.secrets" })
        #expect(reported.group == .error)
        #expect(reported.domain == .plugIn)
        #expect(reported.params?["id"] == .string("com.moonwink.tingra.notes"))
        #expect(reported.params?["name"] == .string("token"))
        #expect(reported.params?["operation"] == .string("write"))
        let values = reported.params?.values.map { "\($0)" } ?? []
        #expect(!values.contains { $0.contains("live_abc") })
    }

    @Test("a method that is not the handler's returns nil")
    func unknownMethodIsNil() async throws {
        let handler = PlugInMethodHandler(plugIn: notes, eventBus: EventBus(), storage: MemoryStore())
        let result = try await handler.respond(method: "tools/call", params: nil)
        #expect(result == nil)
    }

    @Test("tingra/event lands on the bus under the plug-in's domain with its params")
    func eventLandsOnBus() async throws {
        let bus = EventBus()
        let handler = PlugInMethodHandler(plugIn: notes, eventBus: bus, storage: MemoryStore())
        let events = bus.events()
        await handler.handleNotification(
            method: AppTierMethod.event,
            params: .object([
                "name": "notes.edited",
                "params": .object(["characters": .int(12), "nested": .object(["a": .bool(true)])]),
            ]))
        await handler.handleNotification(
            method: AppTierMethod.event, params: .object(["name": "notes.broken", "group": "error"]))
        bus.shutdown()
        var received: [EventBusEvent] = []
        for await event in events { received.append(event) }
        let edited = try #require(received.first { $0.name == "notes.edited" })
        #expect(edited.domain == EventDomain("com.moonwink.tingra.notes"))
        #expect(edited.group == .event)
        #expect(edited.params?["characters"] == .int(12))
        #expect(edited.params?["nested"] == .string("{\"a\":true}"))
        let broken = try #require(received.first { $0.name == "notes.broken" })
        #expect(broken.group == .error)
        #expect(broken.params == nil)
    }

    @Test("an event without a name is reported as an error under the plug-in domain")
    func namelessEventIsReported() async throws {
        let bus = EventBus()
        let handler = PlugInMethodHandler(plugIn: notes, eventBus: bus, storage: MemoryStore())
        let events = bus.events()
        await handler.handleNotification(method: AppTierMethod.event, params: .object(["params": .object([:])]))
        bus.shutdown()
        var received: [EventBusEvent] = []
        for await event in events { received.append(event) }
        #expect(received.first?.name == "plugin.event")
        #expect(received.first?.group == .error)
    }

    @Test("the application store writes one file per plug-in and nil removes it")
    func applicationStoreFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tingra-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlugInApplicationStore(directory: directory)
        #expect(store.value(for: notes) == nil)
        try store.setValue(.object(["fontSize": .double(14)]), for: notes)
        #expect(store.fileURL(for: notes).path().hasSuffix("com.moonwink.tingra.notes/application.json"))
        // A whole number reads back as an integer JSON value; the store is
        // not asked to remember which numeric case wrote it.
        #expect(PlugInApplicationStore(directory: directory).value(for: notes)?["fontSize"]?.doubleValue == 14)
        try store.setValue(nil, for: notes)
        #expect(store.value(for: notes) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: notes).path()))
        try store.setValue(nil, for: notes)
    }
}
