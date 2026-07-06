//
//  ToolRegistryTests.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraPlugInKit

@testable import TingraHost

/// A minimal tool for registry tests.
private struct DummyTool: Tool {
    let name: String
    var title: String { name }
    var description: String { "A dummy tool." }
    var inputSchema: JSONValue { .object(["type": .string("object")]) }
    func call(_ arguments: JSONValue) async throws -> JSONValue { .null }
}

/// The host's tool registry: the seam first- and third-party tool plug-ins
/// register through, mirroring the input and output registries.
@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test("registered tools are listed in registration order and found by name")
    func registersAndResolves() async throws {
        let registry = ToolRegistry()
        try await registry.register(DummyTool(name: "devices_list"))
        try await registry.register(DummyTool(name: "stream_start"))

        #expect(await registry.allTools.map(\.name) == ["devices_list", "stream_start"])
        #expect(await registry.tool(named: "stream_start")?.name == "stream_start")
        #expect(await registry.tool(named: "absent") == nil)
    }

    @Test("registering a duplicate tool name throws")
    func duplicateNameThrows() async throws {
        let registry = ToolRegistry()
        try await registry.register(DummyTool(name: "probe"))
        await #expect(throws: ToolRegistryError.self) {
            try await registry.register(DummyTool(name: "probe"))
        }
    }

    @Test("the duplicate error names the conflicting tool")
    func duplicateErrorNamesTool() async throws {
        let registry = ToolRegistry()
        try await registry.register(DummyTool(name: "probe"))
        do {
            try await registry.register(DummyTool(name: "probe"))
            Issue.record("registering a duplicate should have thrown")
        } catch let error as ToolRegistryError {
            #expect(error == .duplicateTool("probe"))
        }
    }
}
