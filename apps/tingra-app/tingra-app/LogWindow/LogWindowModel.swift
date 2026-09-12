//
//  LogWindowModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import TingraEventBus
import TingraHost

/// The model behind the Log window: the log file's recent lines, followed live
/// while the window is open (ARCHITECTURE.md, "The log window").
///
/// **The file is the source, not a ring.** Opening reads the file's last
/// `LogFile.chunkByteCount` bytes off the main actor, and Load Earlier Lines
/// reads the chunk before that. New lines come from a ``LogWindowSink``
/// attached to the bus only while the window is open and not paused — the file
/// sink runs in this process, so the bus already carries every line the file
/// gets, with no file watcher and no polling. Closing lets every loaded line go;
/// a closed window holds nothing.
///
/// **The seam between the two is handled.** The sink attaches before the read
/// (`attach` subscribes synchronously, so nothing sent afterwards is missed),
/// lines it delivers during the read are held, and once the read lands they are
/// appended less the ones the read already found (``liveLines(_:notIn:)``).
///
/// **Pause holds nothing:** it detaches and freezes the list, and Resume reloads
/// exactly as opening does — the lines written meanwhile are in the file.
/// A `log.cleared` line arriving live empties the list first, which is what the
/// file then holds.
///
/// The `@Observable` rule: `@MainActor`, owned by the ``EngineModel``, read by
/// ``LogWindowView``.
@MainActor
@Observable
final class LogWindowModel {
    /// The loaded lines, oldest first.
    private(set) var lines: [LogWindowLine] = []

    /// Whether the file holds lines before the loaded ones.
    private(set) var hasEarlierLines = false

    /// Whether the window is paused: detached from the bus, the list frozen.
    private(set) var isPaused = false

    /// Whether the opening read is in flight.
    private(set) var isLoading = false

    /// Whether a Load Earlier Lines read is in flight.
    private(set) var isLoadingEarlier = false

    /// Why the last read could not complete, or nil after one that did.
    private(set) var readFailure: String?

    /// What the window shows of the loaded lines. The levels, taps, and launch
    /// choices persist (``LogWindowPreferences``); the domain and search do not.
    var filter: LogWindowFilter {
        didSet {
            if filter.levels != oldValue.levels { preferences.levels = filter.levels }
            if filter.showsTaps != oldValue.showsTaps { preferences.showsTaps = filter.showsTaps }
            if filter.launch != oldValue.launch { preferences.launch = filter.launch }
        }
    }

    /// The file read.
    @ObservationIgnored let logFile: LogFile

    /// This process's log session ID — what This Launch matches, and what the
    /// sink's lines are stamped with.
    @ObservationIgnored let currentSessionID: Int

    /// The host's event bus: the sink attaches to it, and `log.read` goes to it.
    @ObservationIgnored private let eventBus: EventBus

    /// Where the lasting filter choices live.
    @ObservationIgnored private let preferences: LogWindowPreferences

    /// The file sink's format, stamped with ``currentSessionID``.
    @ObservationIgnored private let formatter: LogLineFormatter

    /// How many bytes each read takes.
    @ObservationIgnored private let chunkByteCount: Int

    /// The task draining the sink while it is attached; nil while closed or
    /// paused. Cancelling it detaches the sink.
    @ObservationIgnored private(set) var liveTask: Task<Void, Never>?

    /// Identifies the current attachment, so a line a cancelled sink was still
    /// delivering is recognized as stale and dropped.
    @ObservationIgnored private(set) var attachment = 0

    /// Identifies the current state of the loaded lines, so a read that lands
    /// after a pause, a close, a clear, or a newer read is dropped.
    @ObservationIgnored private var readGeneration = 0

    /// Live lines delivered while the opening read is in flight.
    @ObservationIgnored private var pendingLive: [String] = []

    /// Where in the file the earliest loaded line begins.
    @ObservationIgnored private var earliestOffset: UInt64 = 0

    /// The next line's identity.
    @ObservationIgnored private var nextLineID = 0

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - logFile: The log file to read — the one the file sink appends to.
    ///   - eventBus: The host's event bus.
    ///   - preferences: Where the lasting filter choices live.
    ///   - sessionID: This process's log session ID (default: the process's
    ///     own; tests fix it so no counter file is touched).
    ///   - chunkByteCount: How many bytes each read takes (default:
    ///     `LogFile.chunkByteCount`; tests read smaller chunks).
    init(
        logFile: LogFile,
        eventBus: EventBus,
        preferences: LogWindowPreferences = LogWindowPreferences(),
        sessionID: Int = LogSession.currentID,
        chunkByteCount: Int = LogFile.chunkByteCount
    ) {
        self.logFile = logFile
        self.eventBus = eventBus
        self.preferences = preferences
        self.currentSessionID = sessionID
        self.formatter = LogLineFormatter(sessionID: sessionID)
        self.chunkByteCount = chunkByteCount
        self.filter = LogWindowFilter(
            levels: preferences.levels,
            showsTaps: preferences.showsTaps,
            launch: preferences.launch
        )
    }

    /// The shown lines, in runs by launch.
    var launchGroups: [LogLaunchGroup] {
        LogLaunchGroup.grouping(lines.filter { filter.includes($0.entry, currentSessionID: currentSessionID) })
    }

    /// The distinct domains of the loaded lines, sorted — the domain menu's
    /// choices, found in the lines rather than listed, since plug-ins add their
    /// own.
    var domains: [String] {
        Set(lines.compactMap(\.entry.domain)).sorted()
    }

    /// Whether the sink is attached.
    var isAttached: Bool { liveTask != nil }

    /// Opens the window's view of the log: attaches the sink and reads the
    /// file's last lines.
    func open() async {
        isPaused = false
        await load()
    }

    /// Detaches from the bus and freezes the list. Nothing is buffered: the
    /// lines written while paused are in the file, and ``resume()`` reads them.
    func pause() {
        guard !isPaused else { return }
        detach()
        readGeneration += 1
        isLoading = false
        isLoadingEarlier = false
        pendingLive = []
        isPaused = true
    }

    /// Resumes a paused window by reloading exactly as opening does.
    func resume() async {
        guard isPaused else { return }
        isPaused = false
        await load()
    }

    /// Closes the window's view of the log: detaches and lets every loaded line
    /// go. The filter stays.
    func close() {
        detach()
        readGeneration += 1
        lines = []
        hasEarlierLines = false
        earliestOffset = 0
        pendingLive = []
        isLoading = false
        isLoadingEarlier = false
        isPaused = false
        readFailure = nil
    }

    /// Reads the chunk before the earliest loaded line and puts it at the top.
    /// Does nothing while paused — a paused list is frozen — or while a read is
    /// already in flight.
    func loadEarlier() async {
        guard hasEarlierLines, !isPaused, !isLoading, !isLoadingEarlier else { return }
        let generation = readGeneration
        isLoadingEarlier = true
        do {
            let chunk = try await Self.read(logFile, before: earliestOffset, maxByteCount: chunkByteCount)
            guard generation == readGeneration else { return }
            isLoadingEarlier = false
            readFailure = nil
            lines.insert(contentsOf: chunk.lines.map(line(from:)), at: 0)
            earliestOffset = chunk.startOffset
            hasEarlierLines = chunk.hasEarlierLines
        } catch {
            guard generation == readGeneration else { return }
            isLoadingEarlier = false
            report(error)
        }
    }

    /// Takes one line from the sink: held while the opening read is in flight,
    /// appended otherwise, and dropped when it comes from an attachment that
    /// has since ended.
    ///
    /// - Parameters:
    ///   - text: The formatted line.
    ///   - attachment: The attachment that delivered it.
    func receive(_ text: String, attachment: Int) {
        guard attachment == self.attachment else { return }
        if isLoading {
            pendingLive.append(text)
        } else {
            append(text)
        }
    }

    /// The live lines the tail read did not already contain.
    ///
    /// The file sink and the window's sink receive the same events on
    /// independent streams, so the lines sent after the sink attached may be
    /// partly in the file by the time it is read — as its last lines, and in
    /// the order they were sent. The overlap is therefore the longest run that
    /// ends the tail and begins the live lines, text for text; it is skipped
    /// so no line shows twice.
    ///
    /// - Parameters:
    ///   - live: The lines the sink delivered during the read, oldest first.
    ///   - tail: The lines the read returned, oldest first.
    /// - Returns: The live lines to append.
    nonisolated static func liveLines(_ live: [String], notIn tail: [String]) -> ArraySlice<String> {
        for overlap in stride(from: min(live.count, tail.count), through: 1, by: -1)
        where tail.suffix(overlap).elementsEqual(live.prefix(overlap)) {
            return live.dropFirst(overlap)
        }
        return live[...]
    }

    /// Attaches the sink, then reads the file's last lines, then appends the
    /// live lines the read did not already contain.
    private func load() async {
        detach()
        readGeneration += 1
        let generation = readGeneration
        isLoading = true
        isLoadingEarlier = false
        pendingLive = []
        attach()
        do {
            let chunk = try await Self.read(logFile, before: nil, maxByteCount: chunkByteCount)
            guard generation == readGeneration else { return }
            readFailure = nil
            lines = chunk.lines.map(line(from:))
            earliestOffset = chunk.startOffset
            hasEarlierLines = chunk.hasEarlierLines
            finishLoading(appending: Self.liveLines(pendingLive, notIn: chunk.lines))
        } catch {
            guard generation == readGeneration else { return }
            lines = []
            earliestOffset = 0
            hasEarlierLines = false
            report(error)
            finishLoading(appending: pendingLive[...])
        }
    }

    /// Ends the opening read and appends the live lines held during it.
    ///
    /// - Parameter live: The held lines to append.
    private func finishLoading(appending live: ArraySlice<String>) {
        isLoading = false
        pendingLive = []
        for text in live {
            append(text)
        }
    }

    /// Appends one live line; a `log.cleared` line first empties the list, since
    /// the file now holds only that line.
    ///
    /// - Parameter text: The line.
    private func append(_ text: String) {
        let entry = LogEntry(line: text)
        if entry.name == LogFileModel.clearedEventName, entry.domain == EventDomain.platform.rawValue {
            // A Load Earlier Lines read in flight describes a file that is gone.
            readGeneration += 1
            isLoadingEarlier = false
            lines = []
            earliestOffset = 0
            hasEarlierLines = false
        }
        lines.append(line(from: entry))
    }

    /// A loaded line with the next identity.
    ///
    /// - Parameter text: The line's text.
    /// - Returns: The line.
    private func line(from text: String) -> LogWindowLine {
        line(from: LogEntry(line: text))
    }

    /// A loaded line with the next identity.
    ///
    /// - Parameter entry: The parsed line.
    /// - Returns: The line.
    private func line(from entry: LogEntry) -> LogWindowLine {
        defer { nextLineID += 1 }
        return LogWindowLine(id: nextLineID, entry: entry)
    }

    /// Attaches a fresh sink under a new attachment identity.
    private func attach() {
        attachment += 1
        let attachment = attachment
        liveTask = eventBus.attach(
            LogWindowSink(formatter: formatter) { [weak self] text in
                await self?.receive(text, attachment: attachment)
            }
        )
    }

    /// Detaches the sink, if attached, and ends its attachment identity.
    private func detach() {
        liveTask?.cancel()
        liveTask = nil
        attachment += 1
    }

    /// Records a read that could not complete: shown in the window, and a
    /// `log.read` error on the bus.
    ///
    /// - Parameter error: Why.
    private func report(_ error: any Error) {
        let reason = error.localizedDescription
        readFailure = reason
        eventBus.error("log.read", domain: .platform, params: ["error": .string(reason)])
    }

    /// Reads a chunk of the file off the main actor.
    ///
    /// - Parameters:
    ///   - logFile: The file.
    ///   - offset: The byte the read ends before, or nil for the file's end.
    ///   - maxByteCount: The most bytes to read.
    /// - Returns: The chunk.
    /// - Throws: The file-system error when the file cannot be read.
    @concurrent
    nonisolated private static func read(_ logFile: LogFile, before offset: UInt64?, maxByteCount: Int) async throws
        -> LogFileChunk
    {
        try logFile.lines(before: offset, maxByteCount: maxByteCount)
    }
}
