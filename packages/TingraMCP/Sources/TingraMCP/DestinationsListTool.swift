//
//  DestinationsListTool.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-08-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraHost
import TingraPlugInKit

/// The `destinations_list` tool: the operator's saved destinations, so an
/// agent can turn "my Twitch" into something it can act on (DESTINATIONS.md,
/// "The tool surface").
///
/// **Never a key, and never a fragment of one.** The listing reports `hasKey`
/// — whether a stream key is filed for the destination — which is the only
/// thing an agent needs to know about the secret. That is the point of the
/// store: keys stop transiting agent conversations, so there is deliberately
/// no `destination_add` beside this read. The app remains the editor, where
/// the key is pasted once by the operator.
///
/// **One tool per question.** The listing carries no live leg state, even
/// though a join against the status sink would be easy: `stream_status`
/// already answers "is this destination delivering?", leg identity there is
/// positional rather than a store id, and a store read must answer with
/// nothing streaming at all. An agent that wants both reads both and matches
/// on `url`.
struct DestinationsListTool: Tool {
    /// The operator's destination store the listing is built from.
    private let destinations: DestinationStore

    /// Creates the tool over the operator's destination store.
    ///
    /// - Parameter destinations: The destination store.
    init(destinations: DestinationStore) {
        self.destinations = destinations
    }

    let name = "destinations_list"
    let title = "List Destinations"
    let description =
        "List the destinations the operator saved — id, name, URL, and whether a stream key is stored for "
        + "each. Use a name or id as the 'destination' selector on stream_start and probe. Stream keys are "
        + "never returned; destinations are created and edited in the Tingra app, not by an agent."

    /// No arguments: the listing is the operator's whole store.
    let inputSchema: JSONValue = .object(["type": .string("object")])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        let saved: [StoredDestination]
        do {
            saved = try await destinations.destinations()
        } catch {
            throw StreamCoordinator.toolError(from: error)
        }

        var listed: [JSONValue] = []
        for destination in saved {
            listed.append(
                .object([
                    "id": .string(destination.id.rawValue),
                    "name": .string(destination.name),
                    "url": .string(destination.url.absoluteString),
                    // False, not an error, when this process cannot reach the
                    // Keychain — an unsigned development build. The reason
                    // goes out on the event bus rather than into the result.
                    "hasKey": .bool(await destinations.hasKey(for: destination)),
                ]))
        }
        return .object(["destinations": .array(listed)])
    }
}
