//
//  LogWindowFilter.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost

/// Which launches the log window shows: every launch the loaded lines cover,
/// or only the one running now (ARCHITECTURE.md, "The log window").
enum LogLaunchScope: String, CaseIterable, Sendable {
    /// Every launch in the loaded lines.
    case all
    /// Only this launch — lines whose log session ID is the process's own.
    case current
}

/// What the log window shows of the lines it has loaded: filters on what a
/// line carries — level, taps, domain, launch — and a search over its text.
///
/// Not the event's group, which a line does not record (the level folds several
/// groups into one), and not a param's value, since values are written unquoted
/// (ARCHITECTURE.md, "The log window").
struct LogWindowFilter: Equatable, Sendable {
    /// The levels shown; all of them by default.
    var levels: Set<LogLevel> = Set(LogLevel.allCases)

    /// Whether tap lines are shown. Taps are INFO lines, so hiding Info hides
    /// them too.
    var showsTaps = true

    /// The one domain shown, or nil for every domain.
    var domain: String?

    /// Which launches are shown.
    var launch: LogLaunchScope = .all

    /// The text a shown line contains; empty shows every line.
    var searchText = ""

    /// Whether a line is shown.
    ///
    /// A line that did not parse has no level, domain, or session, so it shows
    /// under every level and the taps choice, and hides only when a domain or
    /// This Launch is chosen — it is never dropped outright.
    ///
    /// - Parameters:
    ///   - entry: The line.
    ///   - currentSessionID: This process's log session ID, for This Launch.
    /// - Returns: Whether it is shown.
    func includes(_ entry: LogEntry, currentSessionID: Int) -> Bool {
        if !searchText.isEmpty, !entry.text.localizedStandardContains(searchText) { return false }
        guard let level = entry.level else { return domain == nil && launch == .all }
        guard levels.contains(level) else { return false }
        if entry.isTap, !showsTaps { return false }
        if let domain, entry.domain != domain { return false }
        if launch == .current, entry.sessionID != currentSessionID { return false }
        return true
    }
}

/// One loaded line and the identity the window's list keys it on — lines are
/// not unique (two identical events in the same millisecond write identical
/// lines), so the position they were loaded in is.
struct LogWindowLine: Identifiable, Hashable, Sendable {
    /// Unique among the lines the window has loaded since it opened.
    let id: Int

    /// The line.
    let entry: LogEntry
}

/// A run of consecutive lines from one launch — what the window draws under
/// one launch header, so interleaved launches in one file read apart.
struct LogLaunchGroup: Identifiable, Equatable, Sendable {
    /// The first line's identity.
    let id: Int

    /// The launch's log session ID, or nil for lines before any parsed line.
    let sessionID: Int?

    /// The lines, oldest first.
    let lines: [LogWindowLine]

    /// Splits lines into runs by launch: a new run starts wherever a parsed
    /// line's log session ID differs from the run before it. A line that did
    /// not parse joins the run it follows.
    ///
    /// - Parameter lines: The lines, oldest first.
    /// - Returns: The runs, oldest first.
    static func grouping(_ lines: [LogWindowLine]) -> [LogLaunchGroup] {
        var groups: [LogLaunchGroup] = []
        var run: [LogWindowLine] = []
        var runSessionID: Int?
        for line in lines {
            if let sessionID = line.entry.sessionID, sessionID != runSessionID {
                if let first = run.first {
                    groups.append(LogLaunchGroup(id: first.id, sessionID: runSessionID, lines: run))
                }
                run = []
                runSessionID = sessionID
            }
            run.append(line)
        }
        if let first = run.first {
            groups.append(LogLaunchGroup(id: first.id, sessionID: runSessionID, lines: run))
        }
        return groups
    }
}
