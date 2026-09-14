//
//  PlugInRuntime.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import SwiftUI
import TingraJSONRPC

/// The extension process's view of its connections to the app: one
/// ``PlugInConnection`` per `NSXPCConnection` the app opens (one per hosted
/// pane, one for commands), and the most recent one as ``connection`` for
/// views that need any connection at all — every connection reaches the
/// same app, so storage and events may go over whichever is open.
///
/// The kit fills it from ``TingraAppExtension``'s default configuration;
/// a pane reads it through `@Environment(PlugInRuntime.self)`.
@MainActor
@Observable
public final class PlugInRuntime {
    /// The one runtime of the extension process.
    public static let shared = PlugInRuntime()

    /// The most recently opened connection, or nil before the app has
    /// connected or after every connection closed.
    public private(set) var connection: PlugInConnection?

    /// Every open connection, oldest first.
    public private(set) var connections: [PlugInConnection] = []

    /// How many connections have been accepted over the process's life.
    public private(set) var acceptedCount = 0

    /// Creates an empty runtime.
    private init() {}

    /// Accepts a connection the app opened: wraps it in a transport and a
    /// ``PlugInConnection``, runs the MCP handshake, and publishes it.
    /// Safe to call from the connection-accepting closures ExtensionKit
    /// runs off the main actor: the transport is built synchronously (so
    /// the connection is resumed before the closure returns) and the
    /// publication hops to the main actor.
    ///
    /// - Parameters:
    ///   - xpcConnection: The connection, not yet resumed.
    ///   - clientName: The plug-in id.
    ///   - clientVersion: The plug-in's version.
    ///   - performCommand: Performs commands the app forwards.
    nonisolated public static func accept(
        _ xpcConnection: NSXPCConnection, clientName: String, clientVersion: String,
        performCommand: @escaping PlugInConnection.CommandHandler
    ) {
        let box = ConnectionBox()
        let transport = XPCMessageTransport(connection: xpcConnection, opening: false) { _ in
            Task { @MainActor in
                if let connection = box.connection { shared.remove(connection) }
            }
        }
        let connection = PlugInConnection(
            transport: transport, clientName: clientName, clientVersion: clientVersion,
            performCommand: performCommand)
        box.connection = connection
        Task { @MainActor in
            shared.add(connection)
            _ = try? await connection.initialize()
        }
    }

    /// Publishes a new connection.
    private func add(_ connection: PlugInConnection) {
        connections.append(connection)
        self.connection = connection
        acceptedCount += 1
    }

    /// Retires a closed connection.
    private func remove(_ connection: PlugInConnection) {
        connections.removeAll { $0 === connection }
        if self.connection === connection { self.connection = connections.last }
    }

    /// Lets the end handler, created before the connection exists, find it.
    private final class ConnectionBox: @unchecked Sendable {
        /// The connection, once created (written once, before any handler
        /// can run: the transport is resumed inside the connection's own
        /// initializer, and the box is filled right after).
        var connection: PlugInConnection?
    }
}
