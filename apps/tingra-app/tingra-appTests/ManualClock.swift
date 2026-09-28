//
//  ManualClock.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

/// A clock that stands still until a test advances it, so a type that waits
/// out an interval on an injected clock is paced by the test, not by how
/// busy the machine running it is.
///
/// A sleep ends when ``advance(by:)`` carries ``now`` to its deadline.
/// ``sleeps`` reports each sleep that starts waiting, so a test advances
/// only once the sleeper is there to be woken: a sleep that began after the
/// advance would measure its deadline from the advanced instant and wait
/// for the next one.
nonisolated final class ManualClock: Clock, Sendable {
    /// A point on the clock: how far it has been advanced from zero.
    struct Instant: InstantProtocol {
        /// The time the clock has been advanced by, up to this instant.
        var offset: Swift.Duration

        /// The instant `duration` after this one.
        ///
        /// - Parameter duration: How far past this instant.
        /// - Returns: The later instant.
        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        /// The time from this instant to `other`.
        ///
        /// - Parameter other: The instant measured to.
        /// - Returns: The time between them, negative when `other` is earlier.
        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        /// Whether `lhs` comes before `rhs`.
        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    /// A sleep waiting for the clock to reach its deadline.
    private struct Sleeper {
        /// When the sleep ends.
        let deadline: Instant

        /// Resumes the sleeping task.
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Everything that changes, behind one lock.
    private struct State {
        /// The current instant.
        var now = Instant(offset: .zero)

        /// The sleeps waiting for the clock, by id.
        var sleepers: [UUID: Sleeper] = [:]
    }

    /// Where a sleep came out when it began: over, cancelled, or waiting
    /// for an advance.
    private enum SleepStart {
        /// The deadline has already been reached.
        case due

        /// The sleeping task was cancelled before the sleep began.
        case cancelled

        /// The sleep waits for an advance to its deadline.
        case waiting
    }

    /// The clock's state.
    private let state = Mutex(State())

    /// Reports each sleep that starts waiting, onto ``sleeps``.
    private let sleepStarted: AsyncStream<Void>.Continuation

    /// One element for each sleep that starts waiting for the clock: what a
    /// test awaits before it advances. One consumer, like any `AsyncStream`.
    let sleeps: AsyncStream<Void>

    /// Creates a clock at zero with no sleeper.
    init() {
        let (sleeps, sleepStarted) = AsyncStream<Void>.makeStream()
        self.sleeps = sleeps
        self.sleepStarted = sleepStarted
    }

    /// The current instant, which moves only when a test advances it.
    var now: Instant {
        state.withLock { $0.now }
    }

    /// The clock resolves any duration.
    var minimumResolution: Swift.Duration {
        .zero
    }

    /// Waits until the clock is advanced to `deadline`, or returns at once
    /// when it already has been.
    ///
    /// - Parameters:
    ///   - deadline: The instant the sleep ends.
    ///   - tolerance: Ignored: the clock only moves when a test moves it.
    /// - Throws: `CancellationError` when the sleeping task is cancelled.
    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checked under the lock, so a cancellation either lands
                // before the sleeper is filed (seen here) or finds it filed.
                let start = state.withLock { state -> SleepStart in
                    guard !Task.isCancelled else { return .cancelled }
                    guard deadline > state.now else { return .due }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .waiting
                }
                switch start {
                case .due:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .waiting:
                    sleepStarted.yield()
                }
            }
        } onCancel: {
            let sleeper = state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward, ending every sleep whose deadline it reaches.
    ///
    /// - Parameter duration: How far to move it.
    func advance(by duration: Swift.Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let ids = state.sleepers.filter { $0.value.deadline <= now }.map(\.key)
            return ids.compactMap { state.sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}
