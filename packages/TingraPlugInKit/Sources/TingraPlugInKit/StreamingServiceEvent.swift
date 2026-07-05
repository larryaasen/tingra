//
//  StreamingServiceEvent.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A connection event reported by a ``StreamingService`` after a
/// successful start (see ``StreamingService/events``).
///
/// The initial connection failing is thrown from
/// ``StreamingService/start(to:)``; these events cover what happens after —
/// state changes no caller is awaiting.
public enum StreamingServiceEvent: Sendable, Equatable {
    /// The connection to the destination was lost. The session decides
    /// whether to reconnect (CLI.md `--reconnect`); the service itself
    /// never retries on its own.
    ///
    /// - Parameter reason: A developer-facing description of what was
    ///   observed (never a secret).
    case connectionLost(reason: String)
}
