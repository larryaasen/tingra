//
//  StdioSocketProxy.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Darwin
import Foundation

/// The transparent byte pipe behind `tingra-cli mcp`: it copies bytes between
/// the agent host (stdin/stdout) and the daemon socket with no protocol logic
/// at all (MCP.md, "Thin edges"). It reconciles the agent host's process
/// lifecycle with the persistent daemon: stdin EOF closes the connection, and
/// the connection closing exits the proxy.
public enum StdioSocketProxy {
    /// Connects to the daemon socket and proxies stdin/stdout to it until the
    /// connection closes, then returns (the `mcp` command then exits).
    ///
    /// - Parameter socketPath: The daemon socket path (``SocketLocation/path``).
    /// - Throws: A ``SocketError`` if the daemon socket cannot be reached.
    public static func run(socketPath: String) async throws {
        let socket = try UnixDomainSocket.connect(path: socketPath)
        defer { Darwin.close(socket) }
        await ByteProxy.pump(
            inputDescriptor: FileHandle.standardInput.fileDescriptor,
            outputDescriptor: FileHandle.standardOutput.fileDescriptor,
            socketDescriptor: socket
        )
    }
}

/// The two-directional byte copy at the heart of the proxy, factored out and
/// fd-based so it is testable with ordinary pipes and socket pairs — no real
/// daemon socket required.
enum ByteProxy {
    /// Pumps bytes in both directions until the socket side closes:
    /// `input → socket` and `socket → output`. On input EOF the socket's write
    /// side is half-closed so the daemon sees end-of-input; on socket EOF the
    /// pump completes and returns.
    ///
    /// - Parameters:
    ///   - inputDescriptor: The source to read from (stdin in the proxy).
    ///   - outputDescriptor: The sink to write to (stdout in the proxy).
    ///   - socketDescriptor: The connected daemon socket.
    static func pump(inputDescriptor: Int32, outputDescriptor: Int32, socketDescriptor: Int32) async {
        // Signalled once the socket → output direction ends (the daemon
        // closed the connection), which is the proxy's exit condition.
        let finished = AsyncQueue<Void>()

        let upstream = Thread {
            copy(from: inputDescriptor, to: socketDescriptor)
            // Input reached EOF: tell the daemon by half-closing our write
            // side, leaving the read side open to drain any final bytes.
            shutdown(socketDescriptor, SHUT_WR)
        }
        upstream.name = "com.moonwink.tingra.mcp.proxy.up"

        let downstream = Thread {
            copy(from: socketDescriptor, to: outputDescriptor)
            finished.enqueue(())
        }
        downstream.name = "com.moonwink.tingra.mcp.proxy.down"

        upstream.start()
        downstream.start()
        _ = await finished.next()
    }

    /// Copies bytes from one descriptor to another until end of input or a
    /// write error, writing every byte of each read.
    private static func copy(from source: Int32, to destination: Int32) {
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(source, raw.baseAddress, capacity)
            }
            guard count > 0 else { break }  // EOF (0) or error (<0).
            let wrote = buffer.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < count {
                    let written = write(destination, base + offset, count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false  // The sink is gone; stop copying.
                    }
                    offset += written
                }
                return true
            }
            if !wrote { break }
        }
    }
}
