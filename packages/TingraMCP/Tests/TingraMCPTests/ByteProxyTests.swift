//
//  ByteProxyTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Darwin
import Foundation
import Testing

@testable import TingraMCP

/// The transparent byte proxy behind `tingra-cli mcp`: bytes flow both ways,
/// stdin EOF half-closes the connection so the daemon sees end-of-input, and
/// the connection closing ends the proxy. Exercised with a socket pair and
/// pipes — no real daemon.
@Suite("ByteProxy")
struct ByteProxyTests {
    /// Writes all of `bytes` to a descriptor.
    private func writeAll(_ descriptor: Int32, _ text: String) {
        let data = Array(text.utf8)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    /// Reads up to `count` bytes from a non-blocking descriptor within a
    /// deadline, returning whatever arrived (empty on immediate EOF).
    private func readBytes(_ descriptor: Int32, count: Int, within seconds: Double = 2) async -> Data {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = ContinuousClock.now + .seconds(seconds)
        while collected.count < count, ContinuousClock.now < deadline {
            let read = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, 1024)
            }
            if read > 0 {
                collected.append(contentsOf: buffer[0..<read])
            } else if read == 0 {
                break  // EOF.
            } else {
                try? await Task.sleep(for: .milliseconds(10))  // EAGAIN on a non-blocking fd.
            }
        }
        return collected
    }

    @Test("bytes flow in both directions, stdin EOF half-closes, and closing the socket ends the proxy")
    func proxiesBothWays() async throws {
        var pair = [Int32](repeating: 0, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let proxySocket = pair[0]
        let daemonSocket = pair[1]

        var stdinPipe = [Int32](repeating: 0, count: 2)
        var stdoutPipe = [Int32](repeating: 0, count: 2)
        #expect(pipe(&stdinPipe) == 0)
        #expect(pipe(&stdoutPipe) == 0)
        let stdinRead = stdinPipe[0]
        let stdinWrite = stdinPipe[1]
        let stdoutRead = stdoutPipe[0]
        let stdoutWrite = stdoutPipe[1]

        // The descriptors the test reads are non-blocking so the async
        // read helper never parks a thread.
        _ = fcntl(daemonSocket, F_SETFL, O_NONBLOCK)
        _ = fcntl(stdoutRead, F_SETFL, O_NONBLOCK)

        let pump = Task {
            await ByteProxy.pump(
                inputDescriptor: stdinRead,
                outputDescriptor: stdoutWrite,
                socketDescriptor: proxySocket
            )
        }

        // stdin → socket
        writeAll(stdinWrite, "hello\n")
        let toDaemon = await readBytes(daemonSocket, count: 6)
        #expect(toDaemon.utf8String == "hello\n")

        // socket → stdout
        writeAll(daemonSocket, "world\n")
        let toStdout = await readBytes(stdoutRead, count: 6)
        #expect(toStdout.utf8String == "world\n")

        // stdin EOF → the daemon sees end-of-input (the write side is
        // half-closed), so its next read returns EOF.
        close(stdinWrite)
        let daemonSawEOF = await readBytes(daemonSocket, count: 1)
        #expect(daemonSawEOF.isEmpty)

        // Closing the socket ends the downstream copy, so the proxy returns.
        close(daemonSocket)
        let finished = await withinTimeout(seconds: 2) { await pump.value }
        #expect(finished)

        close(proxySocket)
        close(stdinRead)
        close(stdoutRead)
        close(stdoutWrite)
    }

    /// Awaits an operation, returning whether it completed before the
    /// timeout (so a hung proxy fails the test instead of hanging it).
    private func withinTimeout(seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
