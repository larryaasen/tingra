//
//  UnixDomainSocket.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Darwin
import Foundation

/// A failure setting up or using the Unix domain socket. Each carries the
/// underlying `errno` so a developer sees the real cause.
enum SocketError: Error, CustomStringConvertible {
    /// `socket(2)` failed.
    case createFailed(Int32)

    /// `bind(2)` failed for the given path.
    case bindFailed(String, Int32)

    /// `listen(2)` failed.
    case listenFailed(Int32)

    /// `connect(2)` failed for the given path.
    case connectFailed(String, Int32)

    /// The socket path exceeds the platform limit for `sun_path`.
    case pathTooLong(String)

    var description: String {
        switch self {
        case .createFailed(let code):
            return "Could not create the socket (errno \(code): \(Self.message(code)))."
        case .bindFailed(let path, let code):
            return "Could not bind the socket at '\(path)' (errno \(code): \(Self.message(code)))."
        case .listenFailed(let code):
            return "Could not listen on the socket (errno \(code): \(Self.message(code)))."
        case .connectFailed(let path, let code):
            return
                "Could not connect to the daemon socket at '\(path)' (errno \(code): \(Self.message(code))). "
                + "Is `tingra-cli serve` running?"
        case .pathTooLong(let path):
            return
                "The socket path is too long for the platform limit of \(UnixSocketAddress.maxPathLength): '\(path)'."
        }
    }

    /// The system message for an `errno`.
    private static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Builds a `sockaddr_un` for a filesystem path and hands it to the socket
/// calls, keeping the pointer gymnastics in one place.
enum UnixSocketAddress {
    /// The `sun_path` capacity on macOS. MCP.md keeps the socket path short
    /// and fixed so it never approaches this limit.
    static let maxPathLength = 104

    /// Runs `body` with a `sockaddr` pointer and length for `path`.
    ///
    /// - Throws: ``SocketError/pathTooLong(_:)`` if the path does not fit.
    static func with<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        let bytes = Array(path.utf8)
        guard bytes.count < maxPathLength else { throw SocketError.pathTooLong(path) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPath in
            rawPath.withMemoryRebound(to: UInt8.self, capacity: maxPathLength) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = byte
                }
                destination[bytes.count] = 0
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &addr) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                try body(socketPointer, length)
            }
        }
    }
}

/// Low-level Unix domain socket operations, isolated so the listener, the
/// transport, and the proxy share one implementation.
enum UnixDomainSocket {
    /// Creates a listening socket bound to `path` (removing any stale socket
    /// file first) and marks it passive.
    ///
    /// - Returns: The listening socket's file descriptor.
    /// - Throws: A ``SocketError`` if any step fails.
    static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.createFailed(errno) }
        // A stale socket file from a previous run would make bind fail with
        // EADDRINUSE; the 0700 directory (SocketLocation) keeps this safe.
        unlink(path)
        do {
            try UnixSocketAddress.with(path: path) { addr, length in
                guard bind(descriptor, addr, length) == 0 else {
                    throw SocketError.bindFailed(path, errno)
                }
            }
            guard Darwin.listen(descriptor, backlog) == 0 else {
                throw SocketError.listenFailed(errno)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Accepts the next connection on a listening socket, blocking until one
    /// arrives.
    ///
    /// - Returns: The accepted connection's file descriptor, or nil if the
    ///   listening socket was closed (accept failed), which ends the loop.
    static func accept(_ listeningDescriptor: Int32) -> Int32? {
        let descriptor = Darwin.accept(listeningDescriptor, nil, nil)
        return descriptor >= 0 ? descriptor : nil
    }

    /// Connects to a daemon socket at `path`.
    ///
    /// - Returns: The connected socket's file descriptor.
    /// - Throws: A ``SocketError`` if the socket cannot be created or reached.
    static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.createFailed(errno) }
        do {
            try UnixSocketAddress.with(path: path) { addr, length in
                guard Darwin.connect(descriptor, addr, length) == 0 else {
                    throw SocketError.connectFailed(path, errno)
                }
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }
}

/// The verified credentials of a socket peer, read from the kernel — defense
/// in depth beyond the `0700` directory (MCP.md, "The transport").
struct PeerCredential {
    /// The peer process's effective user id.
    let uid: uid_t

    /// Reads the peer credentials of a connected socket via
    /// `getsockopt(LOCAL_PEERCRED)`, or nil if they cannot be read.
    static func forSocket(_ descriptor: Int32) -> PeerCredential? {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        let result = withUnsafeMutablePointer(to: &credentials) { pointer in
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, pointer, &length)
        }
        guard result == 0, credentials.cr_version == XUCRED_VERSION else { return nil }
        return PeerCredential(uid: credentials.cr_uid)
    }
}
