//
//  SocketMessageTransport.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Darwin
import Foundation
import Synchronization

/// A ``MessageTransport`` over an accepted Unix domain socket: newline-framed
/// JSON-RPC in both directions (MCP.md, "The transport").
///
/// Blocking socket reads run on a dedicated thread that splits the byte
/// stream on newlines and hands each JSON payload to an ``AsyncQueue``, so
/// the session's read loop simply awaits ``readMessage()`` without ever
/// blocking a cooperative thread. Writes are serialized by a lock — a
/// response and a notification never interleave on the wire. Control-plane
/// traffic is low volume, so a brief blocking write is acceptable here; the
/// per-frame path never touches this transport.
final class SocketMessageTransport: MessageTransport {
    /// The connected socket's file descriptor.
    private let descriptor: Int32

    /// Framed inbound payloads produced by the reader thread.
    private let inbound = AsyncQueue<Data>()

    /// Serializes writes to the descriptor.
    private let writeLock = Mutex<Void>(())

    /// Whether ``close()`` has run, so it is idempotent.
    private let closed = Mutex(false)

    /// Wraps an accepted socket descriptor and starts its reader thread.
    init(descriptor: Int32) {
        self.descriptor = descriptor
        let inbound = self.inbound
        let thread = Thread {
            Self.readLoop(descriptor: descriptor, into: inbound)
        }
        thread.name = "com.moonwink.tingra.mcp.reader"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func readMessage() async throws -> Data? {
        await inbound.next()
    }

    func writeMessage(_ payload: Data) async throws {
        var framed = payload
        framed.append(0x0A)  // The frame delimiter.
        try writeLock.withLock { _ in
            try Self.writeAll(descriptor: descriptor, data: framed)
        }
    }

    func close() async {
        let alreadyClosed = closed.withLock { state -> Bool in
            defer { state = true }
            return state
        }
        guard !alreadyClosed else { return }
        // Closing the descriptor unblocks the reader thread's read(), which
        // finishes the queue and ends the session's read loop.
        Darwin.close(descriptor)
        inbound.finish()
    }

    /// The reader thread: blocking reads, split on newlines, each complete
    /// line enqueued as one JSON payload. Ends the queue at EOF or error.
    private static func readLoop(descriptor: Int32, into queue: AsyncQueue<Data>) {
        var pending = Data()
        let capacity = 4096
        var chunk = [UInt8](repeating: 0, count: capacity)
        while true {
            let count = chunk.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, capacity)
            }
            guard count > 0 else { break }  // EOF (0) or error (<0): peer gone.
            pending.append(contentsOf: chunk[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                if !line.isEmpty {
                    queue.enqueue(line)
                }
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        queue.finish()
    }

    /// Writes every byte of `data`, retrying short and interrupted writes.
    ///
    /// - Throws: The write's `errno` wrapped in a ``SocketError`` if it fails
    ///   for a reason other than interruption.
    private static func writeAll(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.connectFailed("write", errno)
                }
                offset += written
            }
        }
    }
}
