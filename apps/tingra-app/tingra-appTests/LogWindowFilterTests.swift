//
//  LogWindowFilterTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraHost

@testable import TingraApp

@Suite("LogWindowFilter")
struct LogWindowFilterTests {
    /// An INFO line from launch 7.
    private let info = LogEntry(line: " INFO 09-12-2026 10:00:00.000 EDT [0007] @ composition program.take shot=pip")

    /// A DEBUG line from launch 7.
    private let debug = LogEntry(line: "DEBUG 09-12-2026 10:00:01.000 EDT [0007] @ output stream.stats bitrate=4500")

    /// An ERROR line from launch 6.
    private let error = LogEntry(
        line: "ERROR 09-12-2026 10:00:02.000 EDT [0006] @ output stream.connect.timeout attempt=2")

    /// A tap line from launch 7.
    private let tap = LogEntry(line: " INFO 09-12-2026 10:00:03.000 EDT [0007] @ tap=>cut.button")

    /// A line not in the format.
    private let unparsed = LogEntry(line: "a hand-written note")

    /// The lines a filter shows, of all five.
    private func shown(by filter: LogWindowFilter) -> [LogEntry] {
        [info, debug, error, tap, unparsed].filter { filter.includes($0, currentSessionID: 7) }
    }

    @Test("the default filter shows every line")
    func defaultShowsAll() {
        #expect(shown(by: LogWindowFilter()) == [info, debug, error, tap, unparsed])
    }

    @Test("hiding a level hides its lines and nothing else")
    func hidesLevel() {
        #expect(shown(by: LogWindowFilter(levels: [.info, .error])) == [info, error, tap, unparsed])
        #expect(shown(by: LogWindowFilter(levels: [])) == [unparsed])
    }

    @Test("hiding Info hides taps too, since taps are INFO lines")
    func hidingInfoHidesTaps() {
        #expect(!shown(by: LogWindowFilter(levels: [.debug, .error])).contains(tap))
    }

    @Test("hiding taps hides tap lines and keeps the other INFO lines")
    func hidesTaps() {
        #expect(shown(by: LogWindowFilter(showsTaps: false)) == [info, debug, error, unparsed])
    }

    @Test("a domain shows only its lines; taps and unparsed lines have no domain")
    func domain() {
        #expect(shown(by: LogWindowFilter(domain: "output")) == [debug, error])
    }

    @Test("This Launch shows only the current log session's lines")
    func currentLaunch() {
        #expect(shown(by: LogWindowFilter(launch: .current)) == [info, debug, tap])
    }

    @Test("search matches anywhere in the line, ignoring case")
    func search() {
        #expect(shown(by: LogWindowFilter(searchText: "PROGRAM.take")) == [info])
        #expect(shown(by: LogWindowFilter(searchText: "hand-written")) == [unparsed])
        #expect(shown(by: LogWindowFilter(searchText: "no such text")).isEmpty)
    }

    @Test("the filters combine")
    func combined() {
        let filter = LogWindowFilter(levels: [.debug, .error], domain: "output", launch: .current, searchText: "stats")
        #expect(shown(by: filter) == [debug])
    }

    @Test("equal filters compare equal, and a changed field makes them differ")
    func equality() {
        #expect(LogWindowFilter() == LogWindowFilter())
        #expect(LogWindowFilter() != LogWindowFilter(levels: [.error]))
        #expect(LogWindowFilter() != LogWindowFilter(showsTaps: false))
        #expect(LogWindowFilter() != LogWindowFilter(domain: "output"))
        #expect(LogWindowFilter() != LogWindowFilter(launch: .current))
        #expect(LogWindowFilter() != LogWindowFilter(searchText: "x"))
    }
}

@Suite("LogLaunchGroup")
struct LogLaunchGroupTests {
    /// Lines with increasing identities.
    private func lines(_ texts: [String]) -> [LogWindowLine] {
        texts.enumerated().map { LogWindowLine(id: $0.offset, entry: LogEntry(line: $0.element)) }
    }

    /// A line from a launch.
    private func line(session: String) -> String {
        " INFO 09-12-2026 10:00:00.000 EDT [\(session)] @ composition program.take"
    }

    @Test("no lines make no groups")
    func empty() {
        #expect(LogLaunchGroup.grouping([]).isEmpty)
    }

    @Test("a new group starts wherever the log session changes, including back to an earlier one")
    func splitsBySession() {
        let groups = LogLaunchGroup.grouping(
            lines([line(session: "0006"), line(session: "0006"), line(session: "0007"), line(session: "0006")]))

        #expect(groups.map(\.sessionID) == [6, 7, 6])
        #expect(groups.map(\.lines.count) == [2, 1, 1])
        #expect(groups.map(\.id) == [0, 2, 3])
    }

    @Test("an unparsed line joins the group before it; leading ones form a group with no session")
    func unparsedLines() {
        let groups = LogLaunchGroup.grouping(
            lines(["note", line(session: "0007"), "another note", line(session: "0007")]))

        #expect(groups.map(\.sessionID) == [nil, 7])
        #expect(groups.map(\.lines.count) == [1, 3])
    }
}
