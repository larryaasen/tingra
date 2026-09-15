//
//  ResourceRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import TingraHost

/// A minimal resource for registry tests.
private struct DummyResource: Resource {
    let uri: String
    var name: String { uri }
    var title: String { uri }
    var description: String { "A dummy resource." }
    func read() async throws -> JSONValue { .object(["uri": .string(uri)]) }
}

/// The host's resource registry: where the engine's observable state is
/// registered for the MCP/Control service to list, read, and subscribe to,
/// mirroring the tool registry.
@Suite("ResourceRegistry")
struct ResourceRegistryTests {
    @Test("registered resources are listed in registration order and found by URI")
    func registersAndResolves() async throws {
        let registry = ResourceRegistry()
        try await registry.register(DummyResource(uri: "tingra://session"))
        try await registry.register(DummyResource(uri: "tingra://program"))

        #expect(await registry.allResources.map(\.uri) == ["tingra://session", "tingra://program"])
        #expect(await registry.resource(at: "tingra://program")?.uri == "tingra://program")
        #expect(await registry.resource(at: "tingra://absent") == nil)
    }

    @Test("a resource defaults to JSON and to never changing")
    func defaults() async throws {
        let resource = DummyResource(uri: "tingra://session")
        #expect(resource.mimeType == "application/json")
        var signals = 0
        for await _ in resource.changes() { signals += 1 }
        #expect(signals == 0)
    }

    @Test("registering a duplicate URI throws an error naming it")
    func duplicateURIThrows() async throws {
        let registry = ResourceRegistry()
        try await registry.register(DummyResource(uri: "tingra://inputs"))
        do {
            try await registry.register(DummyResource(uri: "tingra://inputs"))
            Issue.record("registering a duplicate should have thrown")
        } catch let error as ResourceRegistryError {
            #expect(error == .duplicateResource("tingra://inputs"))
            #expect(error.description.contains("tingra://inputs"))
        }
    }
}
