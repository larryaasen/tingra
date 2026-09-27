//
//  LogLineTable.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraHost

/// One row of the log window's table: Load Earlier Lines, a launch's header,
/// or a line.
enum LogLineTableRow: Equatable {
    /// Load Earlier Lines, and why a read could not complete — the table's
    /// first row, when shown.
    case earlierLines

    /// The header over one launch's lines.
    ///
    /// - Parameters:
    ///   - groupID: The launch group's identity (its first line's).
    ///   - sessionID: The launch's log session ID.
    case launch(groupID: LogLaunchGroup.ID, sessionID: Int)

    /// One line.
    case line(LogWindowLine)

    /// A row's identity: stable for as long as the row shows the same thing,
    /// so an update can tell rows added at the end from a list that changed.
    enum ID: Hashable {
        /// The Load Earlier Lines row.
        case earlierLines

        /// A launch header, by its group's identity.
        case launch(LogLaunchGroup.ID)

        /// A line, by its identity.
        case line(LogWindowLine.ID)
    }

    /// This row's identity.
    var id: ID {
        switch self {
        case .earlierLines: .earlierLines
        case .launch(let groupID, _): .launch(groupID)
        case .line(let line): .line(line.id)
        }
    }

    /// The table's rows for the shown lines: Load Earlier Lines first when
    /// shown, then each launch's header — none for lines before any line
    /// that parsed — and its lines.
    ///
    /// - Parameters:
    ///   - groups: The shown lines, by launch.
    ///   - showsEarlierLines: Whether the Load Earlier Lines row leads.
    /// - Returns: The rows, top to bottom.
    static func rows(for groups: [LogLaunchGroup], showsEarlierLines: Bool) -> [LogLineTableRow] {
        var rows: [LogLineTableRow] = showsEarlierLines ? [.earlierLines] : []
        rows.reserveCapacity(rows.count + groups.reduce(groups.count) { $0 + $1.lines.count })
        for group in groups {
            if let sessionID = group.sessionID {
                rows.append(.launch(groupID: group.id, sessionID: sessionID))
            }
            rows.append(contentsOf: group.lines.map(LogLineTableRow.line))
        }
        return rows
    }
}

/// How the table's rows changed between two updates — what decides whether
/// the table inserts rows or reloads.
enum LogLineTableChange: Equatable {
    /// The rows are the same.
    case none

    /// Rows were added at the end and nothing else changed: a line arrived.
    case appended(Range<Int>)

    /// Anything else: a load, a Load Earlier Lines, a filter, a clear.
    case reloaded

    /// The change from one set of rows to the next, by identity.
    ///
    /// - Parameters:
    ///   - old: The rows the table shows.
    ///   - new: The rows it should show.
    /// - Returns: The change.
    static func between(_ old: [LogLineTableRow], _ new: [LogLineTableRow]) -> LogLineTableChange {
        let sameRow: (LogLineTableRow, LogLineTableRow) -> Bool = { $0.id == $1.id }
        if old.count == new.count, old.elementsEqual(new, by: sameRow) {
            return .none
        }
        if !old.isEmpty, new.count > old.count, new.prefix(old.count).elementsEqual(old, by: sameRow) {
            return .appended(old.count..<new.count)
        }
        return .reloaded
    }
}

/// The log window's line list: an AppKit table of fixed-height rows, one per
/// line, under a floating header per launch (ARCHITECTURE.md, "The log
/// window").
///
/// AppKit rather than a SwiftUI list, because SwiftUI measured badly at a
/// log's size (2026-09-26, the last 2 MB of Larry's log, 18,623 lines): the
/// lazy `ScrollView` the window first used held 321 MB and grew with every
/// line, at about 0.7 s of main thread per arriving line; a `List` held
/// 37–145 MB but re-measured every row as each line arrived, about 1.6 s a
/// line. A table whose rows have fixed heights never measures a row's content:
/// the same lines took 32 MB and about 11 ms a line. Console lists its
/// messages the same way.
///
/// The table **follows the newest line while it is scrolled to the bottom**:
/// whether it is at the bottom is read just before rows are added, and when
/// it was, the table scrolls to the new last row in the same update — so a
/// line arriving never leaves the bottom by itself, and scrolling up stops
/// the following until the operator scrolls back down.
struct LogLineTable<EarlierLines: View>: NSViewRepresentable {
    /// The rows to show, top to bottom.
    let rows: [LogLineTableRow]

    /// The selected line. The table writes it only when the operator changes
    /// the selection, so a tap-reporting binding records exactly that.
    @Binding var selection: LogWindowLine.ID?

    /// The Load Earlier Lines row's content, hosted in the first row.
    let earlierLines: EarlierLines

    /// Edit ▸ Copy while the table has focus and a line is selected.
    let copyLine: () -> Void

    /// Builds the coordinator that owns the table.
    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, earlierLines: earlierLines, copyLine: copyLine)
    }

    /// Creates the scroll view and its table.
    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    /// Brings the table to the current rows, selection, and handlers.
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(rows: rows, selection: $selection, earlierLines: earlierLines, copyLine: copyLine)
    }

    /// The table's data source and delegate, and the owner of what it shows.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// The rows the table shows.
        private(set) var rows: [LogLineTableRow] = []

        /// Each shown line's row, for putting the selection on the right row
        /// after the rows change.
        private var rowByLineID: [LogWindowLine.ID: Int] = [:]

        /// The table, once made.
        private(set) var table: LogLineTableView?

        /// The selected line.
        private var selection: Binding<LogWindowLine.ID?>

        /// Edit ▸ Copy's action.
        private var copyLine: () -> Void

        /// The Load Earlier Lines row's view.
        private let earlierLinesView: NSHostingView<EarlierLines>

        /// The Load Earlier Lines row's height when the table last asked, so
        /// a change of content (a read's failure appearing) resizes the row.
        private var earlierLinesHeight: CGFloat = 0

        /// True while the table's selection is being changed to match
        /// ``selection`` or by a row change, so that change is not taken for
        /// the operator's.
        private var isSyncingSelection = false

        /// A line's font: SwiftUI's callout, monospaced.
        private let lineFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)

        /// A launch header's font: SwiftUI's caption, semibold.
        private let headerFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)

        /// Creates the coordinator.
        ///
        /// - Parameters:
        ///   - selection: The selected line.
        ///   - earlierLines: The Load Earlier Lines row's content.
        ///   - copyLine: Edit ▸ Copy's action.
        init(selection: Binding<LogWindowLine.ID?>, earlierLines: EarlierLines, copyLine: @escaping () -> Void) {
            self.selection = selection
            self.copyLine = copyLine
            earlierLinesView = NSHostingView(rootView: earlierLines)
        }

        /// A line row's height: one line of the line font, and a point above
        /// and below.
        var lineHeight: CGFloat { Self.textHeight(of: lineFont) + 2 }

        /// A launch header's height: one line of the header font, with three
        /// points above and below.
        var headerHeight: CGFloat { Self.textHeight(of: headerFont) + 6 }

        /// Makes the table inside its scroll view, with this coordinator as
        /// its data source and delegate.
        ///
        /// - Returns: The scroll view.
        func makeScrollView() -> NSScrollView {
            let table = LogLineTableView()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .plain
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.usesAutomaticRowHeights = false
            table.rowHeight = lineHeight
            table.intercellSpacing = .zero
            table.floatsGroupRows = true
            table.allowsMultipleSelection = false
            table.allowsEmptySelection = true
            table.focusRingType = .none
            table.dataSource = self
            table.delegate = self
            table.copyLine = { [weak self] in self?.copyLine() }
            table.canCopyLine = { [weak self] in self?.selectedLineRow != nil }
            self.table = table

            let scrollView = NSScrollView()
            scrollView.documentView = table
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            return scrollView
        }

        /// Brings the table to `rows` — inserting rows when lines were only
        /// added at the end, reloading otherwise — follows the newest line if
        /// the table was at the bottom, and puts the selection back on its
        /// line.
        ///
        /// - Parameters:
        ///   - rows: The rows to show.
        ///   - selection: The selected line.
        ///   - earlierLines: The Load Earlier Lines row's content.
        ///   - copyLine: Edit ▸ Copy's action.
        func update(
            rows newRows: [LogLineTableRow],
            selection: Binding<LogWindowLine.ID?>,
            earlierLines: EarlierLines,
            copyLine: @escaping () -> Void
        ) {
            self.selection = selection
            self.copyLine = copyLine
            earlierLinesView.rootView = earlierLines
            guard let table else { return }

            isSyncingSelection = true
            defer { isSyncingSelection = false }
            let wasAtBottom = isAtBottom
            let change = LogLineTableChange.between(rows, newRows)
            switch change {
            case .none:
                break
            case .appended(let added):
                rows = newRows
                for index in added {
                    if case .line(let line) = newRows[index] { rowByLineID[line.id] = index }
                }
                table.insertRows(at: IndexSet(integersIn: added), withAnimation: [])
            case .reloaded:
                rows = newRows
                rowByLineID = [:]
                for (index, row) in newRows.enumerated() {
                    if case .line(let line) = row { rowByLineID[line.id] = index }
                }
                table.reloadData()
            }
            resizeEarlierLinesRowIfNeeded()
            if change != .none, wasAtBottom, !rows.isEmpty {
                table.scrollRowToVisible(rows.count - 1)
            }
            selectRow(for: selection.wrappedValue)
        }

        /// Whether the table is scrolled to its bottom, within a point or two
        /// — true too when every row fits.
        var isAtBottom: Bool {
            guard let table, let clipView = table.enclosingScrollView?.contentView else { return true }
            return Self.isAtBottom(visibleMaxY: clipView.bounds.maxY, contentHeight: table.frame.height)
        }

        /// Whether a visible rect ending at `visibleMaxY` shows the bottom of
        /// content `contentHeight` tall, with the slack fractional scroll
        /// offsets need.
        ///
        /// - Parameters:
        ///   - visibleMaxY: The bottom of the visible rect, in the table's
        ///     flipped coordinates.
        ///   - contentHeight: The table's height.
        /// - Returns: Whether the bottom is in view.
        static func isAtBottom(visibleMaxY: CGFloat, contentHeight: CGFloat) -> Bool {
            visibleMaxY >= contentHeight - 2
        }

        /// The row of the selected line, when the table's selection is a line.
        private var selectedLineRow: Int? {
            guard let table, rows.indices.contains(table.selectedRow),
                case .line = rows[table.selectedRow]
            else { return nil }
            return table.selectedRow
        }

        /// Selects the row showing `lineID`, or nothing when it is not shown —
        /// a line the filters hide stays selected for the detail area, with
        /// no row to highlight.
        ///
        /// - Parameter lineID: The selected line.
        private func selectRow(for lineID: LogWindowLine.ID?) {
            guard let table else { return }
            let wanted = lineID.flatMap { rowByLineID[$0] }
            guard wanted != selectedLineRow else { return }
            if let wanted {
                table.selectRowIndexes(IndexSet(integer: wanted), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }

        /// Tells the table the Load Earlier Lines row's height changed, when
        /// its content now fits a different height.
        private func resizeEarlierLinesRowIfNeeded() {
            guard let table, rows.first == .earlierLines else { return }
            let height = earlierLinesRowHeight
            guard height != earlierLinesHeight else { return }
            earlierLinesHeight = height
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: 0))
        }

        /// The Load Earlier Lines row's height: its content's, at least a line's.
        private var earlierLinesRowHeight: CGFloat {
            max(earlierLinesView.fittingSize.height, lineHeight)
        }

        /// One line of text's height in a font.
        ///
        /// - Parameter font: The font.
        /// - Returns: The height, rounded up to a whole point.
        private static func textHeight(of font: NSFont) -> CGFloat {
            (font.ascender - font.descender + font.leading).rounded(.up)
        }

        // MARK: NSTableViewDataSource

        /// The number of rows.
        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        // MARK: NSTableViewDelegate

        /// A row's height: a line's, a header's, or the Load Earlier Lines
        /// content's.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rows[row] {
            case .earlierLines:
                earlierLinesHeight = earlierLinesRowHeight
                return earlierLinesHeight
            case .launch: return headerHeight
            case .line: return lineHeight
            }
        }

        /// Launch headers are group rows, so they float at the top while their
        /// lines scroll beneath them.
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .launch = rows[row] { return true }
            return false
        }

        /// Only lines select.
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            if case .line = rows[row] { return true }
            return false
        }

        /// A row's view: the hosted Load Earlier Lines content, a launch
        /// header, or a line, the last two reused as rows scroll.
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch rows[row] {
            case .earlierLines:
                return earlierLinesView
            case .launch(_, let sessionID):
                let session = sessionID.formatted(.number.precision(.integerLength(4...)).grouping(.never))
                let cell = textCell(in: tableView, identifier: "launch", font: headerFont)
                cell.textField?.stringValue = String(
                    localized: "Launch \(session)",
                    comment:
                        "Log window: the header over one launch's lines; the placeholder is the four-digit log session ID"
                )
                cell.textField?.textColor = .secondaryLabelColor
                return cell
            case .line(let line):
                let cell = textCell(in: tableView, identifier: "line", font: lineFont)
                cell.textField?.stringValue = line.entry.text
                cell.textField?.textColor = Self.color(for: line.entry)
                return cell
            }
        }

        /// Takes the operator's change of selection into ``selection``; a
        /// change made to match it, or by rows changing, is not written back.
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            let lineID: LogWindowLine.ID? = selectedLineRow.flatMap { row in
                if case .line(let line) = rows[row] { return line.id }
                return nil
            }
            guard lineID != selection.wrappedValue else { return }
            selection.wrappedValue = lineID
        }

        /// A reused cell holding one truncating line of text, made on first use.
        ///
        /// - Parameters:
        ///   - tableView: The table.
        ///   - identifier: The kind of cell.
        ///   - font: The text's font.
        /// - Returns: The cell.
        private func textCell(in tableView: NSTableView, identifier: String, font: NSFont) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier(identifier)
            if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                return cell
            }
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.font = font
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        /// A line's color: red for ERROR, secondary for DEBUG, the label color
        /// otherwise.
        ///
        /// - Parameter entry: The line.
        /// - Returns: The color.
        private static func color(for entry: LogEntry) -> NSColor {
            switch entry.level {
            case .error: .systemRed
            case .debug: .secondaryLabelColor
            case .info, nil: .labelColor
            }
        }
    }
}

/// The log table, answering Edit ▸ Copy for the selected line.
final class LogLineTableView: NSTableView, NSMenuItemValidation {
    /// Copies the selected line.
    var copyLine: () -> Void = {}

    /// Whether a line is selected to copy.
    var canCopyLine: () -> Bool = { false }

    /// Edit ▸ Copy.
    @objc func copy(_ sender: Any?) {
        copyLine()
    }

    /// Enables Edit ▸ Copy only while a line is selected.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return canCopyLine()
    }
}
