//
//  DestinationsListToolTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-08-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraHost
import TingraPlugInKit

@testable import TingraMCP

@Suite("destinations_list")
struct DestinationsListToolTests {
    /// The tool's result as a list of destination objects.
    ///
    /// - Parameter fixture: The seeded store.
    /// - Returns: The `destinations` array from the result.
    private func list(_ fixture: DestinationFixture) async throws -> [JSONValue] {
        let result = try await DestinationsListTool(destinations: fixture.store).call(.object([:]))
        return try #require(result["destinations"]?.arrayValue)
    }

    @Test("a store with nothing saved lists nothing")
    func emptyStore() async throws {
        let fixture = try await DestinationFixture()
        #expect(try await list(fixture).isEmpty)
    }

    @Test("each destination reports its id, name, url, and whether a key is stored")
    func listsTheRecord() async throws {
        let fixture = try await DestinationFixture(
            destinations: [savedDestination()], keys: ["dest-twitch": "live_abc123"])

        let listed = try #require(try await list(fixture).first?.objectValue)

        #expect(listed["id"] == .string("dest-twitch"))
        #expect(listed["name"] == .string("Twitch"))
        #expect(listed["url"] == .string("rtmp://localhost/live"))
        #expect(listed["hasKey"] == .bool(true))
    }

    @Test("a destination with no stored key reports hasKey false")
    func keylessDestination() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let listed = try #require(try await list(fixture).first?.objectValue)
        #expect(listed["hasKey"] == .bool(false))
    }

    @Test("destinations are listed in the order they were saved")
    func listOrder() async throws {
        let fixture = try await DestinationFixture(destinations: [
            savedDestination(),
            savedDestination(id: "dest-youtube", name: "YouTube", url: "rtmps://a.rtmps.youtube.com/live2"),
        ])

        let listed = try await list(fixture)

        #expect(listed.compactMap { $0["name"]?.stringValue } == ["Twitch", "YouTube"])
    }

    @Test("the result carries the key's presence and never the key or any part of it")
    func neverReturnsAKey() async throws {
        let secret = "live_supersecret123"
        let fixture = try await DestinationFixture(
            destinations: [savedDestination()], keys: ["dest-twitch": secret])

        let result = try await DestinationsListTool(destinations: fixture.store).call(.object([:]))

        let listed = try #require(result["destinations"]?.arrayValue?.first?.objectValue)
        #expect(Set(listed.keys) == ["id", "name", "url", "hasKey"])
        // Belt and braces: nothing anywhere in the encoded result resembles
        // the secret, not even a fragment of it.
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains(secret))
        #expect(!encoded.contains("supersecret"))
        #expect(!encoded.contains("live_"))
    }

    @Test("a key this process cannot read reports hasKey false rather than erroring")
    func unreadableKeyListsFalse() async throws {
        let fixture = try await DestinationFixture(
            destinations: [savedDestination()],
            keys: ["dest-twitch": "live_abc123"],
            readFailure: .keychain(-34018)
        )

        let listed = try #require(try await list(fixture).first?.objectValue)

        // The name and URL resolve either way — the unsigned-development-build
        // degradation (DESTINATIONS.md).
        #expect(listed["name"] == .string("Twitch"))
        #expect(listed["url"] == .string("rtmp://localhost/live"))
        #expect(listed["hasKey"] == .bool(false))
    }

    @Test("a destinations document that does not decode returns a structured error naming the file")
    func unreadableStore() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let fileURL = await fixture.store.fileURL
        try Data("not a destinations document".utf8).write(to: fileURL, options: [.atomic])

        let error = await #expect(throws: ToolError.self) {
            _ = try await DestinationsListTool(destinations: fixture.store).call(.object([:]))
        }

        #expect(error?.identifier == .pipelineError)
        #expect(error?.message.contains(DestinationStore.fileName) == true)
    }

    @Test("the tool takes no arguments and is named for the MCP contract")
    func toolContract() async throws {
        let fixture = try await DestinationFixture()
        let tool = DestinationsListTool(destinations: fixture.store)

        #expect(tool.name == "destinations_list")
        #expect(tool.inputSchema == .object(["type": .string("object")]))
        // Arguments are ignored rather than rejected: an agent sending an
        // empty object and one sending none get the same listing.
        #expect(try await tool.call(.null)["destinations"] != nil)
    }
}
