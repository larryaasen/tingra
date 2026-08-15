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
///
/// The destination is named either inline (`url`/`key`) or by a `destination`
/// selector naming one the operator saved, resolved exactly as `stream_start`
/// resolves it — so "check my backup destination" is answerable without the
/// agent ever holding the key (DESTINATIONS.md, "The tool surface").
struct ProbeTool: Tool {
    /// The output registry resolving a destination scheme to a provider.
    private let outputs: OutputRegistry

    /// The operator's saved destinations a `destination` selector resolves
    /// against, or nil when the embedder configured none.
    private let destinations: DestinationStore?

    /// How long to watch for the destination closing the connection after a
    /// successful publish before declaring it valid.
    private let confirmationSeconds: Double

    /// Creates the tool over the host's output registry.
    ///
    /// - Parameters:
    ///   - outputs: The output registry.
    ///   - destinations: The operator's destination store (default: none).
    ///   - confirmationSeconds: The close-watch window (2s in production,
    ///     shortened in tests).
    init(outputs: OutputRegistry, destinations: DestinationStore? = nil, confirmationSeconds: Double = 2) {
        self.outputs = outputs
        self.destinations = destinations
        self.confirmationSeconds = confirmationSeconds
    }

    let name = "probe"
    let title = "Probe Destination"
    let description =
        "Validate a destination without going live: perform the RTMP handshake, watch briefly for a "
        + "rejection, then disconnect. No media is sent. Name the destination with 'url' (and 'key'), or "
        + "with 'destination' to check one the operator saved — see destinations_list."

    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "url": .object([
                "type": .string("string"),
                "description": .string(
                    "RTMP(S) destination URL to validate. Use this or 'destination', not both."),
            ]),
            "key": .object([
                "type": .string("string"),
                "description": .string("Stream key for 'url'. Never returned or logged."),
            ]),
            "destination": .object([
                "type": .string("string"),
                "description": .string(
                    "A destination the operator saved, by id or by name — its URL and stream key are read "
                        + "from the operator's store, so no key passes through this call."),
            ]),
        ]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        let (urlString, key) = try await resolveTarget(arguments)
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

    /// Resolves the arguments to the URL and key to probe: either the inline
    /// pair, or a saved destination looked up by id or name.
    ///
    /// Exactly one form must be given. `key` alongside `destination` is
    /// refused rather than quietly ignored or quietly preferred — a saved
    /// destination carries its own key, and silently choosing between two
    /// would make the result unreadable.
    ///
    /// - Parameter arguments: The `probe` arguments.
    /// - Returns: The URL string to probe and the key to publish with.
    /// - Throws: A ``ToolError`` with `invalidArgument` for a missing or
    ///   conflicting form, or the store's own identifier-keyed failure for a
    ///   selector that does not resolve.
    private func resolveTarget(_ arguments: JSONValue) async throws -> (url: String, key: String?) {
        let urlString = arguments["url"]?.stringValue
        let selector = arguments["destination"]?.stringValue
        let key = arguments["key"]?.stringValue

        switch (urlString, selector) {
        case (let urlString?, nil):
            return (urlString, key)
        case (nil, let selector?):
            guard key == nil else {
                throw ToolError(
                    identifier: .invalidArgument,
                    message:
                        "A saved destination carries its own stream key, so 'key' does not apply to "
                        + "'destination'. Drop 'key', or name the destination with 'url' instead."
                )
            }
            guard let destinations else {
                throw ToolError(
                    identifier: .destinationNotFound,
                    message:
                        "This engine has no destination store, so the destination selector '\(selector)' "
                        + "cannot be resolved. Pass 'url' (and 'key') instead."
                )
            }
            do {
                let saved = try await destinations.resolve(selector: selector)
                return (saved.url.absoluteString, try await destinations.key(for: saved))
            } catch {
                throw StreamCoordinator.toolError(from: error)
            }
        case (nil, nil):
            throw ToolError(
                identifier: .invalidArgument,
                message: "probe needs somewhere to probe: pass a string 'url', or a saved 'destination'."
            )
        default:
            throw ToolError(
                identifier: .invalidArgument,
                message: "Pass either 'url' or 'destination', not both — probe checks one destination."
            )
        }
    }
}
