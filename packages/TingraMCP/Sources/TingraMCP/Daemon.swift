//
//  Daemon.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Darwin
import Foundation
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// The engine daemon (`tingra-cli serve`): the one owner of the engine that
/// accepts MCP connections over a Unix domain socket, runs an independent
/// ``MCPSession`` per connection against the shared engine, and idle-exits
/// when quiet — but never mid-stream (MCP.md, "Sessions and concurrency" and
/// "Idle exit").
///
/// The daemon is handed an already-listening socket descriptor: `serve`
/// creates it in manual mode, and launchd supplies it via socket activation
/// in the product path (see MCP.md, "Lifecycle"). Everything protocol- and
/// engine-specific is injected, so the daemon owns only the connection
/// lifecycle: accept, verify the peer, serve, and idle-exit.
public actor Daemon {
    /// One live connection's bookkeeping, so shutdown can close it and the
    /// idle guard can count it.
    private struct Connection {
        /// The task running the connection's session.
        let task: Task<Void, Never>

        /// The connection's transport, closed to end the session at shutdown.
        let transport: SocketMessageTransport
    }

    /// The listening socket descriptor (manual-created or launchd-supplied).
    private let listeningDescriptor: Int32

    /// The shared tool registry every session dispatches against.
    private let tools: ToolRegistry

    /// The status sink sessions forward as notifications.
    private let status: StatusSink

    /// The coordinator, read for the idle guard (never idle-exit mid-stream).
    private let coordinator: StreamCoordinator

    /// The event bus carrying the daemon's own lifecycle events.
    private let eventBus: EventBus

    /// The daemon identity reported in each session's `initialize`.
    private let info: DaemonInfo

    /// How long the daemon stays up with no connections and nothing
    /// streaming before exiting, or nil to never idle-exit (development).
    private let idleTimeout: Duration?

    /// Whether to reject peers whose uid differs from the daemon's — defense
    /// in depth beyond the `0700` directory (off only in tests).
    private let verifiesPeerUID: Bool

    /// The live connections, keyed for removal when each ends.
    private var connections: [UUID: Connection] = [:]

    /// The pending idle-exit task, armed when the last connection closes and
    /// cancelled when a new one arrives.
    private var idleTask: Task<Void, Never>?

    /// Whether shutdown has been requested, so it runs once.
    private var stopping = false

    /// Creates a daemon over a listening socket.
    ///
    /// - Parameters:
    ///   - listeningDescriptor: An already-listening Unix domain socket.
    ///   - tools: The shared tool registry.
    ///   - status: The status sink to forward as notifications.
    ///   - coordinator: The stream coordinator (idle guard).
    ///   - eventBus: The event bus for lifecycle events.
    ///   - info: The daemon identity for the handshake.
    ///   - idleTimeout: The quiet period before idle exit, or nil to disable.
    ///   - verifiesPeerUID: Whether to verify each peer's uid (default true).
    public init(
        listeningDescriptor: Int32,
        tools: ToolRegistry,
        status: StatusSink,
        coordinator: StreamCoordinator,
        eventBus: EventBus,
        info: DaemonInfo,
        idleTimeout: Duration?,
        verifiesPeerUID: Bool = true
    ) {
        self.listeningDescriptor = listeningDescriptor
        self.tools = tools
        self.status = status
        self.coordinator = coordinator
        self.eventBus = eventBus
        self.info = info
        self.idleTimeout = idleTimeout
        self.verifiesPeerUID = verifiesPeerUID
    }

    /// Creates a daemon in manual mode: it binds and listens on its own
    /// socket at `socketPath` (the development/debugging path, MCP.md,
    /// "Manual mode"). The socket-activated launchd path instead adopts a
    /// launchd-owned descriptor and constructs the daemon with ``init``.
    ///
    /// - Throws: A ``SocketError`` if the socket cannot be created, bound, or
    ///   listened on.
    public static func manual(
        socketPath: String,
        tools: ToolRegistry,
        status: StatusSink,
        coordinator: StreamCoordinator,
        eventBus: EventBus,
        info: DaemonInfo,
        idleTimeout: Duration?,
        verifiesPeerUID: Bool = true
    ) throws -> Daemon {
        let descriptor = try UnixDomainSocket.listen(path: socketPath)
        return Daemon(
            listeningDescriptor: descriptor,
            tools: tools,
            status: status,
            coordinator: coordinator,
            eventBus: eventBus,
            info: info,
            idleTimeout: idleTimeout,
            verifiesPeerUID: verifiesPeerUID
        )
    }

    /// Runs the daemon until it is shut down (a signal from the front end, or
    /// idle exit). Accepts connections and serves each as an MCP session.
    public func run() async {
        eventBus.event("mcp.daemon.listening", domain: .control, params: ["version": .string(info.version)])
        armIdle()

        // A dedicated thread does the blocking accept(2) and feeds accepted
        // descriptors into the queue this loop consumes — no cooperative
        // thread ever blocks on accept.
        let accepted = AsyncQueue<Int32>()
        let listening = listeningDescriptor
        let acceptThread = Thread {
            while let descriptor = UnixDomainSocket.accept(listening) {
                accepted.enqueue(descriptor)
            }
            accepted.finish()
        }
        acceptThread.name = "com.moonwink.tingra.mcp.accept"
        acceptThread.start()

        while let descriptor = await accepted.next() {
            if stopping {
                Darwin.close(descriptor)
                break
            }
            handleAccepted(descriptor)
        }

        idleTask?.cancel()
        eventBus.event("mcp.daemon.stopped", domain: .control)
    }

    /// Requests an orderly shutdown: stop accepting, close every live
    /// connection (which ends each session), and close the listening socket
    /// so the accept loop returns. Safe to call more than once.
    public func shutdown() {
        guard !stopping else { return }
        stopping = true
        idleTask?.cancel()
        let live = connections.values
        Task {
            for connection in live {
                await connection.transport.close()
            }
        }
        // Closing the listening socket makes the accept thread's accept(2)
        // fail, ending its loop and finishing the queue the run loop awaits.
        Darwin.close(listeningDescriptor)
    }

    /// Serves one accepted connection: verify the peer, then run a session.
    private func handleAccepted(_ descriptor: Int32) {
        guard verifyPeer(descriptor) else {
            eventBus.error(
                "mcp.connection.rejected",
                domain: .control,
                params: [
                    "identifier": .string(ErrorIdentifier.authorizationDenied.rawValue),
                    "message": .string("A connecting peer's user id did not match the daemon's; connection refused."),
                ]
            )
            Darwin.close(descriptor)
            return
        }

        let id = UUID()
        let transport = SocketMessageTransport(descriptor: descriptor)
        let session = MCPSession(transport: transport, tools: tools, status: status, info: info, eventBus: eventBus)
        idleTask?.cancel()
        idleTask = nil
        eventBus.event("mcp.connection.accepted", domain: .control)

        let task = Task { [weak self] in
            await session.run()
            await self?.connectionClosed(id)
        }
        connections[id] = Connection(task: task, transport: transport)
    }

    /// Verifies a peer's uid matches the daemon's, unless verification is
    /// disabled (tests). A peer whose credentials cannot be read is rejected.
    private func verifyPeer(_ descriptor: Int32) -> Bool {
        guard verifiesPeerUID else { return true }
        guard let credential = PeerCredential.forSocket(descriptor) else { return false }
        return credential.uid == getuid()
    }

    /// Removes a finished connection and re-arms the idle guard if it was the
    /// last one.
    private func connectionClosed(_ id: UUID) {
        connections[id] = nil
        if connections.isEmpty {
            armIdle()
        }
    }

    /// Arms the idle-exit timer (when configured): after the quiet period, if
    /// still no connections and nothing streaming, shut down. If a stream is
    /// running with no connections, it re-arms rather than exiting — the
    /// daemon never idle-exits mid-stream.
    private func armIdle() {
        guard let idleTimeout else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.idleFired()
        }
    }

    /// The idle timer fired: exit if quiet, otherwise re-arm.
    private func idleFired() async {
        guard !stopping, connections.isEmpty else { return }
        if await coordinator.isStreaming {
            armIdle()  // Never idle-exit mid-stream; check again later.
            return
        }
        eventBus.event("mcp.daemon.idleExit", domain: .control)
        shutdown()
    }
}
