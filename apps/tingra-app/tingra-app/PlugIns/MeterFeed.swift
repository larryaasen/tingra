//
//  MeterFeed.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Synchronization
import TingraAppPlugInKit
import TingraAudio
import TingraPlugInKit

/// Where a plug-in's connection gets the meters it subscribed to
/// (PLUGINS.md, Decision 18), behind a seam so the method handler is tested
/// with scripted levels and no mixer.
nonisolated protocol PlugInMeterFeeding: Sendable {
    /// The meters as one follower sees them: each element is the window of
    /// mix blocks since the follower's last, and no two arrive closer
    /// together than `interval`. Silent while no block arrives; ends when
    /// the consumer stops.
    ///
    /// - Parameter interval: The least time between two elements.
    /// - Returns: The windows' levels.
    func levels(every interval: Duration) -> AsyncStream<MeterLevels>
}

/// The mix blocks one follower has not been sent yet, folded into one
/// ``MeterLevels``: the rule that lets a hundred blocks a second reach a
/// plug-in as ten notifications without losing what a meter is for.
///
/// A **peak** is the largest of the window's peaks, so a hot sample between
/// two notifications is never dropped — the same reason ``MeterRelay``
/// folds its holds per block. An **RMS** is the root of the mean of the
/// blocks' squared RMS, the window's own loudness, every mix block being
/// the same length. The strips are the **latest** block's: a strip that
/// left the mix mid-window is not reported, and one that joined is reported
/// over the blocks it was in.
nonisolated struct MeterWindow: Sendable {
    /// One meter's fold: the largest peak, and the blocks' squared RMS
    /// summed with their count.
    private struct Fold {
        /// The largest peak folded in.
        var peak: Float = 0

        /// The sum of each block's squared RMS.
        var squares: Double = 0

        /// How many blocks were folded in.
        var count = 0

        /// Folds one block's reading in. A reading that is not a finite
        /// number — no sample the mixer produces, but JSON could not carry
        /// it — counts as silence.
        mutating func fold(_ reading: MeterReading) {
            if reading.peak.isFinite { peak = max(peak, reading.peak) }
            if reading.rms.isFinite { squares += Double(reading.rms) * Double(reading.rms) }
            count += 1
        }

        /// The window's level.
        var level: MeterLevel {
            MeterLevel(peak: Double(peak), rms: count > 0 ? (squares / Double(count)).squareRoot() : 0)
        }
    }

    /// The latest block's time, in seconds.
    private var time: Double = 0

    /// Each strip's fold, for the strips of the latest block.
    private var strips: [InputID: Fold] = [:]

    /// The master's left channel.
    private var masterLeft = Fold()

    /// The master's right channel.
    private var masterRight = Fold()

    /// Whether no block has been folded in.
    private(set) var isEmpty = true

    /// Creates an empty window.
    init() {}

    /// Folds one mix block in.
    ///
    /// - Parameter block: The mix tick's meter block.
    mutating func fold(_ block: MeterBlock) {
        isEmpty = false
        let seconds = block.time.seconds
        time = seconds.isFinite ? seconds : 0
        var latest: [InputID: Fold] = [:]
        for (id, reading) in block.strips {
            var fold = strips[id] ?? Fold()
            fold.fold(reading)
            latest[id] = fold
        }
        strips = latest
        masterLeft.fold(block.master.left)
        masterRight.fold(block.master.right)
    }

    /// The window's levels, or nil when no block was folded in.
    var levels: MeterLevels? {
        guard !isEmpty else { return nil }
        return MeterLevels(
            time: time, strips: strips.mapValues(\.level), masterLeft: masterLeft.level,
            masterRight: masterRight.level)
    }
}

/// The app's meters as plug-ins follow them: the ``EngineModel``'s meter
/// drain folds every mix block in, off the main actor, and each follower is
/// sent its own window of them no more often than it asked
/// (PLUGINS.md, Decision 18) — the ``MeterRelay``'s sibling, which serves
/// the app's own meters at display cadence.
///
/// Driven by the blocks and nothing else: a follower's window fills as
/// blocks arrive, a signal wakes its task, the task sends the window and
/// then waits out the interval while the next window fills. No block, no
/// wake-up, so nothing polls; and with no follower a block costs one lock
/// and an empty dictionary.
nonisolated final class MeterFeed: PlugInMeterFeeding, Sendable {
    /// One follower: the window filling for it, and how it is told that
    /// the window has something in it.
    private struct Follower {
        /// The blocks not yet sent.
        var window = MeterWindow()

        /// Wakes the follower's task; buffers one signal, so a task waiting
        /// out its interval finds the wake-up when it looks again.
        let signal: AsyncStream<Void>.Continuation
    }

    /// The followers, by id.
    private let followers = Mutex<[UUID: Follower]>([:])

    /// Creates a feed with no follower.
    init() {}

    /// Whether anyone is following — for tests, and nothing else.
    var hasFollowers: Bool {
        followers.withLock { !$0.isEmpty }
    }

    /// Folds one mix block into every follower's window and wakes each.
    ///
    /// - Parameter block: The mix tick's meter block.
    func fold(_ block: MeterBlock) {
        followers.withLock { followers in
            for id in followers.keys {
                followers[id]?.window.fold(block)
                followers[id]?.signal.yield(())
            }
        }
    }

    func levels(every interval: Duration) -> AsyncStream<MeterLevels> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            let signals = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { signal in
                followers.withLock { $0[id] = Follower(signal: signal) }
            }
            let task = Task { [weak self] in
                for await _ in signals {
                    guard let levels = self?.takeWindow(of: id) else { continue }
                    continuation.yield(levels)
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                let removed = self?.followers.withLock { $0.removeValue(forKey: id) }
                removed?.signal.finish()
            }
        }
    }

    /// Takes a follower's window, leaving it an empty one to fill.
    ///
    /// - Parameter id: The follower.
    /// - Returns: The window's levels, or nil when it held no block.
    private func takeWindow(of id: UUID) -> MeterLevels? {
        followers.withLock { followers in
            defer { followers[id]?.window = MeterWindow() }
            return followers[id]?.window.levels
        }
    }
}
