//
//  ProbeTool.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost
import TingraPlugInKit

/// The `probe` tool: validate a destination URL/key without going live,
/// mirroring `tingra-cli probe` (CLI.md). Performs the connect + publish
/// handshake, watches briefly for the destination closing the connection
/// (how services reject a bad key), then disconnects — no media is ever sent.
struct ProbeTool: Tool {
    /// The output registry resolving a destination scheme to a provider.
    private let outputs: OutputRegistry

    /// How long to watch for the destination closing the connection after a
    /// successful publish before declaring it valid.
    private let confirmationSeconds: Double

    /// Creates the tool over the host's output registry.
    ///
    /// - Parameters:
    ///   - outputs: The output registry.
    ///   - confirmationSeconds: The close-watch window (2s in production,
    ///     shortened in tests).
    init(outputs: OutputRegistry, confirmationSeconds: Double = 2) {
        self.outputs = outputs
        self.confirmationSeconds = confirmationSeconds
    }

    let name = "probe"
    let title = "Probe Destination"
    let description =
        "Validate a destination URL and stream key without going live: perform the RTMP handshake, "
        + "watch briefly for a rejection, then disconnect. No media is sent."

    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([.string("url")]),
        "properties": .object([
            "url": .object([
                "type": .string("string"),
                "description": .string("RTMP(S) destination URL to validate."),
            ]),
            "key": .object([
                "type": .string("string"),
                "description": .string("Stream key to validate. Never returned or logged."),
            ]),
        ]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        guard let urlString = arguments["url"]?.stringValue else {
            throw ToolError(identifier: .invalidArgument, message: "probe requires a string 'url'.")
        }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            throw ToolError(
                identifier: .invalidArgument, message: "The 'url' value is not a valid URL: '\(urlString)'.")
        }
        guard let provider = await outputs.provider(forScheme: scheme) else {
            throw ToolError(
                identifier: .invalidArgument,
                message:
                    "No registered output serves '\(scheme)://' destinations in v1 — SRT output arrives at "
                    + "roadmap step 8. Probe an rtmp:// or rtmps:// destination."
            )
        }

        let key = arguments["key"]?.stringValue
        let destination = Destination(url: url, streamKey: key)
        let service = provider.makeStreamingService(configuration: StreamConfiguration())
        do {
            try await service.start(to: destination)
        } catch {
            throw StreamCoordinator.toolError(from: error)
        }

        // Watch for the destination closing the connection right after
        // accepting the publish — how a bad key is usually rejected.
        let lost = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in service.events {
                    if case .connectionLost = event { return true }
                }
                return false
            }
            group.addTask { [confirmationSeconds] in
                try? await Task.sleep(for: .seconds(confirmationSeconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await service.stop()

        if lost {
            throw ToolError(
                identifier: .connectionFailed,
                message:
                    "The destination accepted the handshake but closed the connection immediately — with most "
                    + "services that means the stream key was rejected."
            )
        }
        return .object([
            "url": .string(urlString),
            "valid": .bool(true),
            "keyChecked": .bool(key != nil),
        ])
    }
}
