//
//  StreamHistoryModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-10-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import TingraEventBus
import TingraHost

/// The app's view of the stream history — the model behind the Streaming
/// settings pane's history (ARCHITECTURE.md, "Stream history").
///
/// The history itself is the host's: the entries and their rules are
/// `StreamHistory`, and the file is `StreamHistoryStore`. What is the app's
/// is what this type adds — it makes the history observable for the pane,
/// saves it after each change, and reports on the event bus, since the app
/// is what knows a clear was the operator's.
///
/// **Driven by the stream's own events, never polled** (CLAUDE.md): the
/// ``EngineModel`` calls ``begin(destinations:width:height:frameRate:at:)``
/// when the session reports `stream.started` and ``end(reason:at:)`` when it
/// reports `stream.stopped` or the app quits on air, each with the event's
/// own date. The entry is written to disk at the start, not only at the end,
/// so a session cut off by a crash still has its start on record, and
/// ``markOnAir(at:)`` stamps it on each `stream.stats` line — once a minute —
/// so it has a length too.
///
/// The history is read from disk when the model is first used, and the
/// model is made lazily by the engine model — so a launch that never opens
/// the pane and never streams reads nothing.
///
/// The `@Observable` rule: `@MainActor`, owned by the ``EngineModel``, read
/// by the pane.
@MainActor
@Observable
final class StreamHistoryModel {
    /// The history as it stands.
    private(set) var history = StreamHistory()

    /// Why the last ``clear()`` could not remove the history, in the
    /// operator's words; nil before a clear and after one that worked.
    private(set) var clearFailure: String?

    /// Where the history persists.
    @ObservationIgnored private let store: StreamHistoryStore

    /// The host's event bus, for the `stream.history.*` events.
    @ObservationIgnored private let eventBus: EventBus

    /// Creates the model and reads the history.
    ///
    /// A file that cannot be read as a history is reported as a
    /// `stream.history.load` error and set aside under an `.unreadable`
    /// name, and the model starts empty: a damaged record must not stop the
    /// next session from being recorded, and must not be overwritten either.
    ///
    /// - Parameters:
    ///   - store: Where the history persists.
    ///   - eventBus: The host's event bus.
    init(store: StreamHistoryStore, eventBus: EventBus) {
        self.store = store
        self.eventBus = eventBus
        do {
            history = StreamHistory(entries: try store.read())
        } catch {
            eventBus.error(
                "stream.history.load",
                domain: .platform,
                params: ["error": .string(ProjectStore.eventDescription(of: error))])
            try? store.setAsideUnreadableFile()
        }
    }

    /// The streamed sessions, oldest first.
    var entries: [StreamHistoryEntry] { history.entries }

    /// The figures over the whole history.
    var summary: StreamHistorySummary { history.summary }

    /// Whether there is nothing to show or clear.
    var isEmpty: Bool { history.isEmpty }

    /// Whether an entry is the session on air now.
    ///
    /// - Parameter entry: The entry to test.
    /// - Returns: Whether it is still running.
    func isOnAir(_ entry: StreamHistoryEntry) -> Bool {
        history.isOnAir(entry)
    }

    /// Records a session going on air, as the next session number, and
    /// saves.
    ///
    /// - Parameters:
    ///   - destinations: The names of the destinations the program went on
    ///     air to, in the panel's order.
    ///   - width: The program's width in pixels.
    ///   - height: The program's height in pixels.
    ///   - frameRate: The program's frame rate.
    ///   - date: When the program went on air.
    func begin(destinations: [String], width: Int, height: Int, frameRate: Int, at date: Date) {
        history.begin(destinations: destinations, width: width, height: height, frameRate: frameRate, at: date)
        save()
    }

    /// Records the session on air ending, and saves. A no-op when none is on
    /// air — a stop reported twice, or one for a session that never went on
    /// air.
    ///
    /// - Parameters:
    ///   - reason: How it ended.
    ///   - date: When it ended.
    func end(reason: StreamHistoryEndReason, at date: Date) {
        guard history.end(reason: reason, at: date) else { return }
        save()
    }

    /// Notes that the session on air is still on air, and saves — what gives
    /// a session cut off by a crash a length. A no-op when none is on air.
    ///
    /// - Parameter date: A moment the session was on air.
    func markOnAir(at date: Date) {
        guard history.markOnAir(at: date) else { return }
        save()
    }

    /// Removes the whole history, the session on air included, and records
    /// the outcome on the bus: one `stream.history.cleared` event carrying
    /// how many sessions it held, or a `stream.history.clear` error with the
    /// reason, which ``clearFailure`` also shows the operator. The next
    /// streamed session is session 1 again.
    ///
    /// - Returns: Whether the history was removed.
    @discardableResult
    func clear() -> Bool {
        do {
            try store.remove()
        } catch {
            let reason = ProjectStore.eventDescription(of: error)
            clearFailure = reason
            eventBus.error("stream.history.clear", domain: .platform, params: ["error": .string(reason)])
            return false
        }
        eventBus.event("stream.history.cleared", domain: .platform, params: ["sessions": .int(entries.count)])
        history.removeAll()
        clearFailure = nil
        return true
    }

    /// Writes the history, reporting a write that could not complete as a
    /// `stream.history.save` error. The entries stay in memory either way,
    /// so the pane shows the session and the next change tries again.
    private func save() {
        do {
            try store.write(entries)
        } catch {
            eventBus.error(
                "stream.history.save",
                domain: .platform,
                params: ["error": .string(ProjectStore.eventDescription(of: error))])
        }
    }
}
