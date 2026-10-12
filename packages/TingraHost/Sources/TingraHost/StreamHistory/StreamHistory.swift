//
//  StreamHistory.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The stream history: every streamed session the operator has put on air,
/// oldest first, and which of them — if any — is on air now
/// (ARCHITECTURE.md, "Stream history").
///
/// A value holding the rules and nothing else: how sessions are numbered,
/// what a start and an end do to the list, and what tells a session still
/// running from one whose end was never seen. It reads no clock and touches
/// no file — the front end passes each moment in from the event that
/// reported it (`stream.started`, `stream.stopped`) and persists the entries
/// through ``StreamHistoryStore`` — so the rules are the same in every front
/// end and are tested without a file system.
///
/// ``activeNumber`` is deliberately not persisted. A history read back from
/// disk has nothing on air, so an entry with no end found there is a session
/// that was cut off — a crash, a Force Quit — and reads as ended
/// unexpectedly, with no end and a length counted to the last moment it was
/// known to be on air (``markOnAir(at:)``).
public struct StreamHistory: Equatable, Sendable {
    /// The streamed sessions, oldest first.
    public private(set) var entries: [StreamHistoryEntry]

    /// The number of the session on air now, or nil when none is.
    public private(set) var activeNumber: Int?

    /// Creates a history from the sessions read from disk, with nothing on
    /// air.
    ///
    /// - Parameter entries: The streamed sessions, oldest first (empty by
    ///   default).
    public init(entries: [StreamHistoryEntry] = []) {
        self.entries = entries
        self.activeNumber = nil
    }

    /// The figures over the whole history.
    public var summary: StreamHistorySummary { StreamHistorySummary(entries) }

    /// Whether the history holds no session.
    public var isEmpty: Bool { entries.isEmpty }

    /// Whether an entry is the session on air now.
    ///
    /// - Parameter entry: The entry to test.
    /// - Returns: Whether it is still running.
    public func isOnAir(_ entry: StreamHistoryEntry) -> Bool {
        entry.endedAt == nil && entry.number == activeNumber
    }

    /// Records a session going on air, as the next session number: one more
    /// than the last entry's, or 1 in an empty history.
    ///
    /// A session already open is closed first at the same moment, as
    /// stopped: v1 runs one stream at a time, so a second start means the
    /// first one's end was missed, and an entry left open would later read
    /// as a crash that did not happen.
    ///
    /// - Parameters:
    ///   - destinations: The names of the destinations the program went on
    ///     air to, in the front end's order.
    ///   - width: The program's width in pixels.
    ///   - height: The program's height in pixels.
    ///   - frameRate: The program's frame rate.
    ///   - date: When the program went on air.
    /// - Returns: The new entry.
    @discardableResult
    public mutating func begin(
        destinations: [String], width: Int, height: Int, frameRate: Int, at date: Date
    ) -> StreamHistoryEntry {
        end(reason: .stopped, at: date)
        let entry = StreamHistoryEntry(
            number: (entries.last?.number ?? 0) + 1,
            startedAt: date,
            destinations: destinations,
            width: width,
            height: height,
            frameRate: frameRate
        )
        entries.append(entry)
        activeNumber = entry.number
        return entry
    }

    /// Records the session on air ending. Changes nothing when none is on
    /// air — a stop reported twice, or one for a session that never went on
    /// air.
    ///
    /// - Parameters:
    ///   - reason: How it ended.
    ///   - date: When it ended.
    /// - Returns: Whether a session was closed, so the caller knows there is
    ///   something to save.
    @discardableResult
    public mutating func end(reason: StreamHistoryEndReason, at date: Date) -> Bool {
        defer { activeNumber = nil }
        guard let activeNumber, let index = entries.lastIndex(where: { $0.number == activeNumber }) else {
            return false
        }
        entries[index].endedAt = date
        entries[index].endReason = reason
        return true
    }

    /// Notes that the session on air is still on air at a moment, so its
    /// length is known up to then even if its end is never seen. Changes
    /// nothing when none is on air, or when the moment is not later than the
    /// last one noted.
    ///
    /// - Parameter date: A moment the session was on air.
    /// - Returns: Whether the entry changed, so the caller knows there is
    ///   something to save.
    @discardableResult
    public mutating func markOnAir(at date: Date) -> Bool {
        guard let activeNumber, let index = entries.lastIndex(where: { $0.number == activeNumber }) else {
            return false
        }
        guard date > (entries[index].lastOnAirAt ?? entries[index].startedAt) else { return false }
        entries[index].lastOnAirAt = date
        return true
    }

    /// Removes every session, the one on air included. The next streamed
    /// session is session 1 again.
    public mutating func removeAll() {
        entries = []
        activeNumber = nil
    }
}
