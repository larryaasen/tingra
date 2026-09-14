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
import TingraJSONRPC
import TingraPlugInKit

@testable import TingraApp

/// An in-memory plug-in store, keyed by scope and plug-in.
private final class MemoryStore: PlugInStoring {
    /// The values.
    let values = Mutex<[String: JSONValue]>([:])

    func value(scope: StorageScope, plugIn: PlugInID) async -> JSONValue? {
        values.withLock { $0["\(scope.rawValue):\(plugIn.rawValue)"] }
    }

    func setValue(_ value: JSONValue?, scope: StorageScope, plugIn: PlugInID) async {
        values.withLock { $0["\(scope.rawValue):\(plugIn.rawValue)"] = value }
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
