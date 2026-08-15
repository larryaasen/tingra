//
//  ProbeToolTests.swift
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

@Suite("probe")
struct ProbeToolTests {
    /// An output registry serving rtmp through a mock service, so a probe
    /// completes the handshake without a network.
    ///
    /// - Returns: The registry.
    private func mockOutputs() async throws -> OutputRegistry {
        let outputs = OutputRegistry()
        try await outputs.register(MockProvider(service: MockStreamingService()))
        return outputs
    }

    /// The error a probe call throws, or nil when it succeeds.
    ///
    /// - Parameters:
    ///   - arguments: The `probe` arguments.
    ///   - destinations: The store to resolve a selector against, if any.
    /// - Returns: The thrown ``ToolError``, or nil.
    private func probeError(_ arguments: JSONValue, destinations: DestinationStore? = nil) async throws
        -> ToolError?
    {
        let tool = ProbeTool(
            outputs: try await mockOutputs(), destinations: destinations, confirmationSeconds: 0.01)
        do {
            _ = try await tool.call(arguments)
            return nil
        } catch let error as ToolError {
            return error
        }
    }

    // MARK: - Naming the destination

    @Test("a probe with neither a url nor a destination returns an invalidArgument error")
    func namesNowhere() async throws {
        #expect(try await probeError(.object([:]))?.identifier == .invalidArgument)
    }

    @Test("a probe naming both a url and a destination returns an invalidArgument error")
    func namesTwoPlaces() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let error = try await probeError(
            ["url": "rtmp://localhost/live", "destination": "Twitch"], destinations: fixture.store)
        #expect(error?.identifier == .invalidArgument)
    }

    @Test("a key alongside a saved destination returns an invalidArgument error")
    func keyWithSavedDestination() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let error = try await probeError(
            ["destination": "Twitch", "key": "live_abc123"], destinations: fixture.store)
        #expect(error?.identifier == .invalidArgument)
        #expect(error?.message.contains("carries its own stream key") == true)
    }

    @Test("a url that is not a URL returns an invalidArgument error")
    func malformedURL() async throws {
        #expect(try await probeError(["url": "not a url at all"])?.identifier == .invalidArgument)
    }

    // MARK: - Resolving a saved destination

    @Test("a saved destination is probed at its stored url, with its stored key")
    func probesSavedDestination() async throws {
        let fixture = try await DestinationFixture(
            destinations: [savedDestination()], keys: ["dest-twitch": "live_abc123"])
        let tool = ProbeTool(
            outputs: try await mockOutputs(), destinations: fixture.store, confirmationSeconds: 0.01)

        let result = try await tool.call(["destination": "Twitch"])

        #expect(result["url"] == .string("rtmp://localhost/live"))
        #expect(result["valid"] == .bool(true))
        #expect(result["keyChecked"] == .bool(true))
    }

    @Test("a saved destination with no stored key probes keyless")
    func probesKeylessSavedDestination() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let tool = ProbeTool(
            outputs: try await mockOutputs(), destinations: fixture.store, confirmationSeconds: 0.01)

        let result = try await tool.call(["destination": "dest-twitch"])

        #expect(result["keyChecked"] == .bool(false))
    }

    @Test("a selector matching nothing returns destinationNotFound")
    func unknownSelector() async throws {
        let fixture = try await DestinationFixture(destinations: [savedDestination()])
        let error = try await probeError(["destination": "vimeo"], destinations: fixture.store)
        #expect(error?.identifier == .destinationNotFound)
    }

    @Test("a name matching several destinations returns destinationAmbiguous")
    func ambiguousSelector() async throws {
        let fixture = try await DestinationFixture(destinations: [
            savedDestination(id: "dest-1", name: "Twitch main"),
            savedDestination(id: "dest-2", name: "Twitch backup", url: "rtmp://localhost/backup"),
        ])
        let error = try await probeError(["destination": "twitch"], destinations: fixture.store)
        #expect(error?.identifier == .destinationAmbiguous)
    }

    @Test("a selector with no destination store configured returns destinationNotFound")
    func noStoreConfigured() async throws {
        let error = try await probeError(["destination": "Twitch"])
        #expect(error?.identifier == .destinationNotFound)
        #expect(error?.message.contains("no destination store") == true)
    }

    @Test("a stored key this process cannot read returns an error naming the fix")
    func unreadableKey() async throws {
        let fixture = try await DestinationFixture(
            destinations: [savedDestination()],
            keys: ["dest-twitch": "live_abc123"],
            readFailure: .keychain(-34018)
        )

        let error = try await probeError(["destination": "Twitch"], destinations: fixture.store)

        #expect(error?.identifier == .pipelineError)
        #expect(error?.message.contains("separate binaries in separate groups") == true)
    }
}
