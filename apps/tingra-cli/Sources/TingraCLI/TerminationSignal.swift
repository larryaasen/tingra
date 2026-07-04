//
//  TerminationSignal.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Awaitable Ctrl-C / SIGTERM, for the commands that run until stopped
/// (`devices --watch`; `stream` joins at roadmap step 3). A clean stop
/// exits 0 (CLI.md), so the default terminate-on-signal disposition must
/// be replaced with something the structured-concurrency world can await.
///
/// Implementation: the classic self-pipe. The C signal handler may only
/// call async-signal-safe functions — no allocation, no locks, so no
/// continuation resuming and no `AsyncStream.yield` — and `write(2)` is
/// on the safe list. The handler writes one byte; the async side awaits
/// the pipe's read end. No GCD anywhere.
enum TerminationSignal {
    /// The pipe's write end, reachable from the C handler. Written once
    /// during `wait()` setup, before the handlers are installed, and never
    /// mutated after — which is what makes the unsafe opt-out sound.
    private nonisolated(unsafe) static var writeDescriptor: Int32 = -1

    /// Suspends until the process receives SIGINT or SIGTERM. Call at
    /// most once per process (the CLI's run-until-stopped commands are
    /// one-shot).
    static func wait() async {
        let pipe = Pipe()
        writeDescriptor = pipe.fileHandleForWriting.fileDescriptor
        signal(SIGINT, handleSignal)
        signal(SIGTERM, handleSignal)
        var bytes = pipe.fileHandleForReading.bytes.makeAsyncIterator()
        _ = try? await bytes.next()
    }
}

/// The C signal handler: async-signal-safe by construction — one `write`,
/// nothing else.
private func handleSignal(_ signalNumber: Int32) {
    var byte = UInt8(0)
    _ = withUnsafeBytes(of: &byte) { buffer in
        write(TerminationSignal.signalWriteDescriptor, buffer.baseAddress, 1)
    }
}

extension TerminationSignal {
    /// The handler's read access to the pipe descriptor (fileprivate so
    /// the free-function handler can reach it).
    fileprivate static var signalWriteDescriptor: Int32 { writeDescriptor }
}
