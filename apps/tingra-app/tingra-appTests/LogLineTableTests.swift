//
//  LogLineTableTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import Testing
import TingraHost

@testable import TingraApp

/// A selection a test reads back: the binding the table writes through.
@MainActor
private final class SelectionBox {
    /// The selected line.
    var value: LogWindowLine.ID?

    /// How many times the table wrote the selection.
    private(set) var writes = 0

    /// A binding over ``value`` that counts writes.
    var binding: Binding<LogWindowLine.ID?> {
        Binding {
            self.value
        } set: { newValue in
            self.writes += 1
            self.value = newValue
        }
    }
}

/// The log window's table: its rows, how it tells an arriving line from a
/// changed list, when it follows the bottom, and its selection.
@Suite("LogLineTable")
@MainActor
struct LogLineTableTests {
    /// A line from a launch, with an identity.
    ///
    /// - Parameters:
    ///   - id: The line's identity.
    ///   - session: The launch's four-digit log session ID.
    /// - Returns: The line.
    private func line(_ id: Int, session: String = "0007") -> LogWindowLine {
        LogWindowLine(
            id: id, entry: LogEntry(line: " INFO 09-12-2026 10:00:00.000 EDT [\(session)] @ composition line\(id)"))
    }

    /// The rows for lines grouped by launch.
    ///
    /// - Parameters:
    ///   - lines: The lines.
    ///   - showsEarlierLines: Whether Load Earlier Lines leads.
    /// - Returns: The rows.
    private func rows(_ lines: [LogWindowLine], showsEarlierLines: Bool = false) -> [LogLineTableRow] {
        LogLineTableRow.rows(for: LogLaunchGroup.grouping(lines), showsEarlierLines: showsEarlierLines)
    }

    /// A coordinator with its table made, showing `rows`.
    ///
    /// - Parameters:
    ///   - rows: The rows.
    ///   - selection: The selection it writes.
    /// - Returns: The coordinator and its table.
    private func table(
        showing rows: [LogLineTableRow], selection: SelectionBox
    ) throws -> (LogLineTable<EmptyView>.Coordinator, LogLineTableView) {
        let coordinator = LogLineTable<EmptyView>.Coordinator(
            selection: selection.binding, earlierLines: EmptyView(), copyLine: {})
        let scrollView = coordinator.makeScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        coordinator.update(rows: rows, selection: selection.binding, earlierLines: EmptyView(), copyLine: {})
        return (coordinator, try #require(coordinator.table))
    }

    @Test("rows put Load Earlier Lines first, then each launch's header over its lines")
    func rowsAreFlattenedByLaunch() {
        let lines = [line(0, session: "0007"), line(1, session: "0007"), line(2, session: "0008")]

        let result = rows(lines, showsEarlierLines: true)

        #expect(
            result.map(\.id) == [
                .earlierLines, .launch(0), .line(0), .line(1), .launch(2), .line(2),
            ])
    }

    @Test("lines before any parsed line get no header")
    func unparsedLinesHaveNoHeader() {
        let unparsed = LogWindowLine(id: 0, entry: LogEntry(line: "a line that is not the file's format"))

        #expect(rows([unparsed]).map(\.id) == [.line(0)])
    }

    @Test("the same rows are no change")
    func sameRowsAreNoChange() {
        let before = rows([line(0), line(1)])

        #expect(LogLineTableChange.between(before, before) == .none)
    }

    @Test("a line arriving in the same launch is appended")
    func arrivingLineIsAppended() {
        let before = rows([line(0), line(1)])
        let after = rows([line(0), line(1), line(2)])

        #expect(LogLineTableChange.between(before, after) == .appended(3..<4))
    }

    @Test("a line starting a new launch appends its header with it")
    func newLaunchAppendsHeader() {
        let before = rows([line(0)])
        let after = rows([line(0), line(1, session: "0008")])

        #expect(LogLineTableChange.between(before, after) == .appended(2..<4))
    }

    @Test(
        "loading earlier lines, filtering, clearing, and the first load reload",
        arguments: [
            (before: [1, 2], after: [0, 1, 2]),
            (before: [0, 1, 2], after: [0, 2]),
            (before: [0, 1, 2], after: [3]),
            (before: [], after: [0, 1]),
        ]
    )
    func otherChangesReload(before: [Int], after: [Int]) {
        let change = LogLineTableChange.between(rows(before.map { line($0) }), rows(after.map { line($0) }))

        #expect(change == .reloaded)
    }

    @Test("the bottom is in view within two points, and always when the rows fit")
    func bottomDetection() {
        typealias Coordinator = LogLineTable<EmptyView>.Coordinator
        #expect(Coordinator.isAtBottom(visibleMaxY: 1000, contentHeight: 1000))
        #expect(Coordinator.isAtBottom(visibleMaxY: 998, contentHeight: 1000))
        #expect(!Coordinator.isAtBottom(visibleMaxY: 990, contentHeight: 1000))
        #expect(Coordinator.isAtBottom(visibleMaxY: 200, contentHeight: 50))
    }

    @Test("the table shows every row, and an arriving line adds one")
    func tableTracksRows() throws {
        let selection = SelectionBox()
        let (coordinator, table) = try table(showing: rows((0..<100).map { line($0) }), selection: selection)
        #expect(table.numberOfRows == 101)

        coordinator.update(
            rows: rows((0..<101).map { line($0) }), selection: selection.binding, earlierLines: EmptyView(),
            copyLine: {})

        #expect(table.numberOfRows == 102)
    }

    @Test("a table at the bottom follows an arriving line; one scrolled up stays put")
    func followsOnlyAtBottom() throws {
        let selection = SelectionBox()
        let (coordinator, table) = try table(showing: rows((0..<100).map { line($0) }), selection: selection)
        #expect(coordinator.isAtBottom)

        coordinator.update(
            rows: rows((0..<101).map { line($0) }), selection: selection.binding, earlierLines: EmptyView(),
            copyLine: {})
        #expect(coordinator.isAtBottom)

        let clipView = try #require(table.enclosingScrollView?.contentView)
        clipView.scroll(to: .zero)
        #expect(!coordinator.isAtBottom)
        coordinator.update(
            rows: rows((0..<102).map { line($0) }), selection: selection.binding, earlierLines: EmptyView(),
            copyLine: {})
        #expect(!coordinator.isAtBottom)
    }

    @Test("only lines select, and the operator's selection is written back")
    func operatorSelectionIsWritten() throws {
        let selection = SelectionBox()
        let (coordinator, table) = try table(showing: rows([line(0), line(1)]), selection: selection)

        #expect(!coordinator.tableView(table, shouldSelectRow: 0))
        #expect(coordinator.tableView(table, shouldSelectRow: 1))
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)

        #expect(selection.value == 1)
        #expect(selection.writes == 1)
        #expect(table.canCopyLine())
    }

    @Test("a selection set from outside selects its row without being written back")
    func outsideSelectionIsNotWrittenBack() throws {
        let selection = SelectionBox()
        let (coordinator, table) = try table(showing: rows([line(0), line(1)]), selection: selection)
        #expect(!table.canCopyLine())

        selection.value = 0
        coordinator.update(
            rows: rows([line(0), line(1)]), selection: selection.binding, earlierLines: EmptyView(), copyLine: {})

        #expect(table.selectedRow == 1)
        #expect(selection.writes == 0)
    }

    @Test("Edit ▸ Copy runs the copy action")
    func copyRunsAction() throws {
        let selection = SelectionBox()
        var copies = 0
        let coordinator = LogLineTable<EmptyView>.Coordinator(
            selection: selection.binding, earlierLines: EmptyView(), copyLine: { copies += 1 })
        _ = coordinator.makeScrollView()
        let table = try #require(coordinator.table)

        table.copy(nil)

        #expect(copies == 1)
    }
}
