//
//  StreamHistoryFormat.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition
import TingraHost

/// How the stream history's figures read in the Streaming settings pane:
/// a length of time on air, when a session ran, and the format it ran at.
///
/// Apart from the views so the wording is tested without drawing anything,
/// and taking the locale and time zone as parameters so a test names its
/// own rather than reading the machine's.
enum StreamHistoryFormat {
    /// A length of time on air, in hours, minutes, and seconds — whichever
    /// of them are not zero.
    ///
    /// - Parameters:
    ///   - seconds: The length, in seconds; rounded to a whole second.
    ///   - locale: The locale to format in (the current one by default).
    /// - Returns: For example "1h 6m 3s".
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        Duration.seconds(Int64(seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow).locale(locale))
    }

    /// When a session ran: its start through its end, or its start alone
    /// while it has no recorded end.
    ///
    /// - Parameters:
    ///   - entry: The session.
    ///   - locale: The locale to format in (the current one by default).
    ///   - timeZone: The time zone to show the times in (the current one by
    ///     default).
    /// - Returns: For example "Oct 11, 2026, 3:04 – 4:10 PM".
    static func period(
        of entry: StreamHistoryEntry, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        guard let endedAt = entry.endedAt, endedAt > entry.startedAt else {
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
            style.timeZone = timeZone
            return entry.startedAt.formatted(style)
        }
        var style = Date.IntervalFormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return (entry.startedAt..<endedAt).formatted(style)
    }

    /// The program format a session ran at, worded as the status bar words
    /// it (``ProgramFormatChoice/label(for:)``).
    ///
    /// - Parameter entry: The session.
    /// - Returns: For example "1920×1080 · 30 fps".
    static func programFormat(of entry: StreamHistoryEntry) -> String {
        ProgramFormatChoice.label(
            for: ProgramFormat(width: entry.width, height: entry.height, frameRate: entry.frameRate))
    }

    /// The destinations a session went on air to, as one list.
    ///
    /// - Parameters:
    ///   - entry: The session.
    ///   - locale: The locale to format in (the current one by default).
    /// - Returns: For example "Twitch and YouTube"; empty for a session with
    ///   none recorded.
    static func destinations(of entry: StreamHistoryEntry, locale: Locale = .current) -> String {
        entry.destinations.formatted(.list(type: .and, width: .standard).locale(locale))
    }
}
