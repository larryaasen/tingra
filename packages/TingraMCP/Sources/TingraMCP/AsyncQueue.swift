//
//  AsyncQueue.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Synchronization

/// A single-consumer async FIFO: a producer enqueues elements in order and
/// one consumer awaits ``next()``. It bridges the daemon's blocking socket
/// I/O — a reader thread producing framed message payloads, an accept thread
/// producing connection file descriptors — into structured concurrency,
/// where the read loop simply awaits the next element.
///
/// Ordering is preserved exactly, and it is Swift-6 strict-concurrency clean:
/// a lock-protected buffer with a single suspended waiter, never an
/// `AsyncStream` iterator smuggled across an isolation boundary.
/// Continuations are resumed after the lock is released.
final class AsyncQueue<Element: Sendable>: Sendable {
    /// The queue's protected state.
    private struct State {
        /// Elements produced but not yet consumed.
        var buffer: [Element] = []

        /// Whether the producer has finished; a later read then returns nil.
        var finished = false

        /// The single consumer suspended in ``next()``.
        var waiter: CheckedContinuation<Element?, Never>?
    }

    /// The lock-protected state.
    private let state = Mutex(State())

    /// Creates an empty queue.
    init() {}

    /// Enqueues one element, resuming a waiting consumer if one is suspended.
    /// Ignored once finished.
    func enqueue(_ element: Element) {
        let waiter = state.withLock { state -> CheckedContinuation<Element?, Never>? in
            guard !state.finished else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.buffer.append(element)
            return nil
        }
        waiter?.resume(returning: element)
    }

    /// Marks the producer finished; a waiting (or later) consumer gets nil.
    /// Idempotent.
    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<Element?, Never>? in
            state.finished = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }

    /// Awaits the next element, or nil once finished and drained. Single
    /// consumer only.
    func next() async -> Element? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
            // Resolve under the lock, resume after releasing it.
            let resume: () -> Void = state.withLock { state in
                if !state.buffer.isEmpty {
                    let element = state.buffer.removeFirst()
                    return { continuation.resume(returning: element) }
                }
                if state.finished {
                    return { continuation.resume(returning: nil) }
                }
                state.waiter = continuation
                return {}
            }
            resume()
        }
    }
}
