//
//  LogWindowView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraEventBus
import TingraHost

/// The Log window: the log file's recent lines, followed live, filtered by
/// level, taps, domain, launch, and search (ARCHITECTURE.md, "The log window").
///
/// A lazy list of one monospaced row per line, truncated at the window's width
/// — ERROR lines in red, DEBUG lines in the secondary color — under a header
/// per launch, with the selected line shown whole in a detail area beneath,
/// Console's pattern, so a long line is readable without wrapping every row.
/// Line text is the file's and is never localized; the window's own labels are.
///
/// The list **follows the newest line while it is scrolled to the bottom** and
/// stops following when the operator scrolls up, Console's and Xcode's
/// behavior: whether the list sits at the bottom is read from the scroll
/// geometry, and settles into *following* only when a scroll the operator made
/// comes to rest, so a line arriving — which briefly leaves the bottom out of
/// view — never turns following off by itself.
///
/// The model opens when the window appears and closes when it goes away, so a
/// closed window holds no lines and no sink (``LogWindowModel``).
struct LogWindowView: View {
    /// The engine model — for its event bus (every control reports a `tap`) and
    /// its log window model.
    let model: EngineModel

    /// The selected line's identity.
    @State private var selection: LogWindowLine.ID?

    /// The list's scroll position, starting at the newest line.
    @State private var position = ScrollPosition(edge: .bottom)

    /// Whether the list is scrolled to the bottom, as of the last geometry
    /// change.
    @State private var isAtBottom = true

    /// Whether new lines scroll the list to the bottom.
    @State private var isFollowing = true

    /// Whether the list has keyboard focus, so Edit ▸ Copy copies the selected
    /// line.
    @FocusState private var isListFocused: Bool

    /// How close to the bottom counts as at the bottom, in points — the slack
    /// fractional scroll offsets need.
    private static let bottomTolerance: CGFloat = 2

    /// The log window model.
    private var log: LogWindowModel { model.logWindowModel }

    /// The window.
    var body: some View {
        let groups = log.launchGroups
        VStack(spacing: 0) {
            lineList(groups: groups)
            Divider()
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                levelsMenu
                domainPicker
                launchPicker
                pauseButton
            }
        }
        .searchable(
            text: Bindable(log).filter.searchText,
            placement: .toolbar,
            prompt: Text("Search Log", comment: "Log window: the search field's placeholder")
        )
        .task {
            await log.open()
        }
        .onDisappear {
            log.close()
        }
    }

    /// The lines, in runs by launch, with Load Earlier Lines at the top.
    ///
    /// - Parameter groups: The shown lines, by launch.
    /// - Returns: The list.
    private func lineList(groups: [LogLaunchGroup]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if log.hasEarlierLines || (log.readFailure != nil && !log.lines.isEmpty) {
                    earlierLinesRow
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.lines) { line in
                            row(for: line)
                        }
                    } header: {
                        launchHeader(for: group)
                    }
                }
            }
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - Self.bottomTolerance
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .onScrollPhaseChange { _, phase in
            if phase == .idle {
                isFollowing = isAtBottom
            }
        }
        .onChange(of: log.lines.last?.id) {
            guard isFollowing, !log.isPaused else { return }
            position.scrollTo(edge: .bottom)
        }
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        .onCopyCommand {
            copySelection()
        }
        .overlay {
            emptyState(groups: groups)
        }
    }

    /// Load Earlier Lines, and the reason a read could not complete when lines
    /// are already showing.
    private var earlierLinesRow: some View {
        VStack(spacing: 4) {
            if log.hasEarlierLines {
                Button {
                    model.eventBus.tap("logLoadEarlier.button", domain: .platform)
                    Task { await log.loadEarlier() }
                } label: {
                    Text(
                        "Load Earlier Lines",
                        comment: "Log window: button at the top of the list that reads older lines")
                }
                .disabled(log.isPaused || log.isLoadingEarlier)
            }
            if let failure = log.readFailure, !log.lines.isEmpty {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// One line's row: the text on one line, colored by level, selectable.
    ///
    /// - Parameter line: The line.
    /// - Returns: The row.
    private func row(for line: LogWindowLine) -> some View {
        // An empty line still takes a row's height.
        Text(verbatim: line.entry.text.isEmpty ? " " : line.entry.text)
            .font(.callout.monospaced())
            .foregroundStyle(Self.color(for: line.entry))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(selection == line.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            .contentShape(.rect)
            .onTapGesture {
                model.eventBus.tap("logLine.row", domain: .platform)
                selection = line.id
                isListFocused = true
            }
    }

    /// The header over one launch's lines, naming its log session; none for
    /// lines before any line that parsed.
    ///
    /// - Parameter group: The launch's lines.
    /// - Returns: The header.
    @ViewBuilder
    private func launchHeader(for group: LogLaunchGroup) -> some View {
        if let sessionID = group.sessionID {
            let session = sessionID.formatted(.number.precision(.integerLength(4...)).grouping(.never))
            Text(
                "Launch \(session)",
                comment:
                    "Log window: the header over one launch's lines; the placeholder is the four-digit log session ID"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.bar)
        }
    }

    /// The selected line, whole, with its text selectable.
    private var detail: some View {
        ScrollView {
            Group {
                if let line = selectedLine {
                    Text(verbatim: line.entry.text)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text(
                        "Select a line to read it whole.",
                        comment: "Log window: placeholder in the detail area when no line is selected"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(height: 88)
    }

    /// What the list says when it shows nothing: why the file could not be
    /// read, that there is no log yet, or that the filters hide every line.
    ///
    /// - Parameter groups: The shown lines, by launch.
    /// - Returns: The empty state, or nothing when lines show.
    @ViewBuilder
    private func emptyState(groups: [LogLaunchGroup]) -> some View {
        if log.lines.isEmpty, let failure = log.readFailure {
            ContentUnavailableView {
                Label {
                    Text("Couldn’t Read the Log", comment: "Log window: title when the log file cannot be read")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
            } description: {
                Text(failure)
            }
        } else if log.lines.isEmpty, !log.isLoading {
            ContentUnavailableView {
                Label {
                    Text("No Log Yet", comment: "Log window: title when the log file holds no lines")
                } icon: {
                    Image(systemName: "doc.text")
                }
            } description: {
                Text(
                    "Tingra writes a line here for everything it does.",
                    comment: "Log window: description when the log file holds no lines"
                )
            }
        } else if !log.lines.isEmpty, groups.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No Lines Match", comment: "Log window: title when the filters hide every line")
                } icon: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            } description: {
                Text(
                    "Change the filters or the search to see more.",
                    comment: "Log window: description when the filters hide every line"
                )
            }
        }
    }

    /// The level and taps filters, as checkable items in one menu.
    private var levelsMenu: some View {
        Menu {
            ForEach(LogLevel.allCases, id: \.self) { level in
                Toggle(isOn: levelBinding(level)) {
                    Self.title(for: level)
                }
            }
            Divider()
            Toggle(
                isOn: Bindable(log).filter.showsTaps.reportingTap(
                    to: model.eventBus, "logTaps.picker", domain: .platform
                ) { shown in
                    ["shown": .bool(shown)]
                }
            ) {
                Text("Taps", comment: "Log window: the filter that shows or hides tap lines")
            }
        } label: {
            Label {
                Text("Levels", comment: "Log window: the toolbar menu of level and tap filters")
            } icon: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }
    }

    /// The domain filter: every domain, or one found in the loaded lines.
    private var domainPicker: some View {
        Picker(
            selection: Bindable(log).filter.domain.reportingTap(
                to: model.eventBus, "logDomain.picker", domain: .platform
            ) { choice in
                ["domain": .string(choice ?? "all")]
            }
        ) {
            Text("All Domains", comment: "Log window: the domain filter's choice that shows every domain")
                .tag(String?.none)
            Divider()
            ForEach(domainChoices, id: \.self) { domain in
                Text(verbatim: domain)
                    .tag(String?.some(domain))
            }
        } label: {
            Text("Domain", comment: "Log window: label of the domain filter")
        }
        .pickerStyle(.menu)
    }

    /// The launch filter: every launch, or this one.
    private var launchPicker: some View {
        Picker(
            selection: Bindable(log).filter.launch.reportingTap(
                to: model.eventBus, "logLaunch.picker", domain: .platform
            ) { scope in
                ["launch": .string(scope.rawValue)]
            }
        ) {
            Text("All Launches", comment: "Log window: the launch filter's choice that shows every launch")
                .tag(LogLaunchScope.all)
            Text("This Launch", comment: "Log window: the launch filter's choice that shows only this launch")
                .tag(LogLaunchScope.current)
        } label: {
            Text("Launch", comment: "Log window: label of the launch filter")
        }
        .pickerStyle(.menu)
    }

    /// Pause, or Resume while paused.
    private var pauseButton: some View {
        Button {
            model.eventBus.tap("logPause.button", domain: .platform, params: ["paused": .bool(!log.isPaused)])
            if log.isPaused {
                Task { await log.resume() }
            } else {
                log.pause()
            }
        } label: {
            if log.isPaused {
                Label {
                    Text("Resume", comment: "Log window: toolbar button that follows the log again after a pause")
                } icon: {
                    Image(systemName: "play.fill")
                }
            } else {
                Label {
                    Text("Pause", comment: "Log window: toolbar button that freezes the list")
                } icon: {
                    Image(systemName: "pause.fill")
                }
            }
        }
    }

    /// The domain menu's choices: the loaded lines' domains, plus the chosen
    /// one when a clear has taken its lines away, so the menu still names it.
    private var domainChoices: [String] {
        var choices = log.domains
        if let chosen = log.filter.domain, !choices.contains(chosen) {
            choices.append(chosen)
            choices.sort()
        }
        return choices
    }

    /// The selected line, when it is still loaded.
    private var selectedLine: LogWindowLine? {
        guard let selection else { return nil }
        return log.lines.first { $0.id == selection }
    }

    /// A binding to whether one level shows, reporting its tap.
    ///
    /// - Parameter level: The level.
    /// - Returns: The binding.
    private func levelBinding(_ level: LogLevel) -> Binding<Bool> {
        let log = log
        return Binding {
            log.filter.levels.contains(level)
        } set: { shown in
            if shown {
                log.filter.levels.insert(level)
            } else {
                log.filter.levels.remove(level)
            }
        }
        .reportingTap(to: model.eventBus, "logLevel.picker", domain: .platform) { shown in
            ["level": .string(level.rawValue), "shown": .bool(shown)]
        }
    }

    /// Edit ▸ Copy: the selected line's text.
    ///
    /// - Returns: The line, or nothing when no line is selected.
    private func copySelection() -> [NSItemProvider] {
        guard let line = selectedLine else { return [] }
        model.eventBus.tap("logCopy.command", domain: .platform)
        return [NSItemProvider(object: line.entry.text as NSString)]
    }

    /// A level's name in the levels menu.
    ///
    /// - Parameter level: The level.
    /// - Returns: The name.
    private static func title(for level: LogLevel) -> Text {
        switch level {
        case .info: Text("Info", comment: "Log window: the level filter for INFO lines")
        case .debug: Text("Debug", comment: "Log window: the level filter for DEBUG lines")
        case .error: Text("Errors", comment: "Log window: the level filter for ERROR lines")
        }
    }

    /// A line's color: red for ERROR, secondary for DEBUG, primary otherwise.
    ///
    /// - Parameter entry: The line.
    /// - Returns: The color.
    private static func color(for entry: LogEntry) -> Color {
        switch entry.level {
        case .error: .red
        case .debug: .secondary
        case .info, nil: .primary
        }
    }
}
