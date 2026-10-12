//
//  StreamHistoryEntry.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// How a streamed session ended, as the stream history records it.
///
/// The history's own vocabulary rather than ``StreamSession/Outcome``'s,
/// because the history also records an ending the session never reports: the
/// front end quitting with the program still on air.
public enum StreamHistoryEndReason: String, Codable, Equatable, Sendable {
    /// The operator stopped the stream.
    case stopped

    /// Every destination was lost and not recovered within its reconnect
    /// budget.
    case connectionLost

    /// The front end quit while the program was on air; the stream went with
    /// the process.
    case appQuit
}

/// One streamed session in the stream history: a stretch the program was on
/// air, from the session's `stream.started` to its end (ARCHITECTURE.md,
/// "Stream history").
///
/// A session that never went on air — every destination refused it at start
/// — is not a streamed session and has no entry. An entry with no
/// ``endedAt`` is either the session on air now or one whose end was never
/// seen (a crash, a Force Quit); ``StreamHistory`` tells the two apart. Such
/// an entry still has a length, counted to ``lastOnAirAt``.
///
/// The JSON keys are spelled out, so the file's shape is the contract.
public struct StreamHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    /// The session number: 1 for the first streamed session recorded, one
    /// more for each after it. Never reused while the history is kept.
    public let number: Int

    /// When the program went on air.
    public let startedAt: Date

    /// When the session ended, or nil while it is on air — or for good, when
    /// its end was never seen.
    public var endedAt: Date?

    /// How the session ended, or nil with ``endedAt``.
    public var endReason: StreamHistoryEndReason?

    /// The last moment the session was known to be on air, or nil before the
    /// first such report. Stamped as the session reports its delivery while
    /// it runs, so a session whose end was never seen still says how long it
    /// was on air — to within the interval between reports, and never more
    /// than it really was.
    public var lastOnAirAt: Date?

    /// The names of the destinations the program went on air to, in the
    /// front end's order — each the operator's name for it, or its URL when
    /// it has none. A destination that refused the connection at start is not
    /// listed. Names rather than ids: the history must still read after a
    /// destination is renamed or removed.
    public let destinations: [String]

    /// The program's width in pixels.
    public let width: Int

    /// The program's height in pixels.
    public let height: Int

    /// The program's frame rate, in frames per second.
    public let frameRate: Int

    /// The session number, for `ForEach`.
    public var id: Int { number }

    /// How long the program was on air: to its recorded end, else to the
    /// last moment it was known to be on air (``lastOnAirAt``), else nil —
    /// a session that has reported nothing since it started. Never negative:
    /// a wall clock set back mid-stream reads as zero rather than as time
    /// owed.
    public var duration: TimeInterval? {
        (endedAt ?? lastOnAirAt).map { max(0, $0.timeIntervalSince(startedAt)) }
    }

    /// Creates an entry.
    ///
    /// - Parameters:
    ///   - number: The session number.
    ///   - startedAt: When the program went on air.
    ///   - endedAt: When the session ended, or nil.
    ///   - endReason: How the session ended, or nil.
    ///   - lastOnAirAt: The last moment it was known to be on air, or nil.
    ///   - destinations: The names of the destinations it went on air to.
    ///   - width: The program's width in pixels.
    ///   - height: The program's height in pixels.
    ///   - frameRate: The program's frame rate.
    public init(
        number: Int,
        startedAt: Date,
        endedAt: Date? = nil,
        endReason: StreamHistoryEndReason? = nil,
        lastOnAirAt: Date? = nil,
        destinations: [String],
        width: Int,
        height: Int,
        frameRate: Int
    ) {
        self.number = number
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.lastOnAirAt = lastOnAirAt
        self.destinations = destinations
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    /// The JSON keys.
    enum CodingKeys: String, CodingKey {
        case number
        case startedAt
        case endedAt
        case endReason
        case lastOnAirAt
        case destinations
        case width
        case height
        case frameRate
    }
}

/// The stream history's overall figures: how many sessions were streamed and
/// how long the program was on air across them.
public struct StreamHistorySummary: Equatable, Sendable {
    /// How many streamed sessions the history holds, the one on air included.
    public let sessionCount: Int

    /// The time on air summed over every session's ``StreamHistoryEntry/duration``:
    /// to its end where one was recorded, and to the last moment it was
    /// known to be on air for the session running now and for one whose end
    /// was never seen.
    public let totalDuration: TimeInterval

    /// Summarizes a history.
    ///
    /// - Parameter entries: The history's entries, in any order.
    public init(_ entries: [StreamHistoryEntry]) {
        self.sessionCount = entries.count
        self.totalDuration = entries.compactMap(\.duration).reduce(0, +)
    }
}
