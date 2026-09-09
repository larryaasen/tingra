//
//  LogFileModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import TingraEventBus
import TingraHost

/// The model behind the Logging settings pane: the log file's size as of the
/// last look, and the two things an operator does to the file — take a
/// snapshot to share, and clear it (ARCHITECTURE.md, "The log file and the
/// Logging settings pane").
///
/// **Refreshed on events, never polled** (CLAUDE.md): the size is read when
/// the pane appears and again after each action the pane takes — the moments
/// the pane is looking and the answer has changed by more than a line. The
/// file grows by one line per event while the pane is open, and a size that
/// is a few lines behind is the honest reading of a file being written.
///
/// It is where the file's bus events come from: `LogFile` in the host emits
/// nothing, because the app is what knows a clear was the operator's. The
/// `@Observable` rule: `@MainActor`, owned by the ``EngineModel``, read by
/// the pane.
@MainActor
@Observable
final class LogFileModel {
    /// The file's size in bytes as of the last ``refresh()``, or nil when
    /// there is no file yet.
    private(set) var byteCount: Int64?

    /// Why the last ``clear()`` could not empty the file, in the operator's
    /// words; nil before a clear and after one that worked.
    private(set) var clearFailure: String?

    /// The file.
    @ObservationIgnored let logFile: LogFile

    /// The host's event bus, for the `log.*` events.
    @ObservationIgnored private let eventBus: EventBus

    /// Creates the model over a log file.
    ///
    /// - Parameters:
    ///   - logFile: The file.
    ///   - eventBus: The host's event bus.
    init(logFile: LogFile, eventBus: EventBus) {
        self.logFile = logFile
        self.eventBus = eventBus
    }

    /// Whether the file exists, as of the last ``refresh()``.
    var exists: Bool { byteCount != nil }

    /// Whether there is nothing to share or clear: no file, or an empty one.
    var isEmpty: Bool { (byteCount ?? 0) == 0 }

    /// Re-reads the size.
    func refresh() {
        byteCount = logFile.byteCount
    }

    /// Copies the log to a dated snapshot for sharing and returns it, or
    /// nil — recorded as a `log.snapshot` error — when there is nothing to
    /// copy or the copy could not be written.
    ///
    /// - Returns: The snapshot, or nil.
    func snapshot() -> URL? {
        defer { refresh() }
        do {
            return try logFile.snapshot()
        } catch {
            eventBus.error("log.snapshot", domain: .platform, params: ["error": .string(Self.reason(for: error))])
            return nil
        }
    }

    /// Empties the file in place, records the outcome on the bus, and
    /// re-reads the size so the pane shows what is left.
    ///
    /// One `log.cleared` event carries how many bytes the file held
    /// (`previousBytes`), and lands in the emptied file as its first line —
    /// so a short log read later says it was deliberately cleared rather
    /// than looking truncated by accident. A clear that could not complete
    /// is a `log.clear` error carrying the reason, which ``clearFailure``
    /// also shows the operator.
    ///
    /// - Returns: Whether the file was emptied.
    @discardableResult
    func clear() -> Bool {
        defer { refresh() }
        do {
            let previous = try logFile.clear()
            clearFailure = nil
            eventBus.event("log.cleared", domain: .platform, params: ["previousBytes": .int(Int(previous))])
            return true
        } catch {
            let reason = Self.reason(for: error)
            clearFailure = reason
            eventBus.error("log.clear", domain: .platform, params: ["error": .string(reason)])
            return false
        }
    }

    /// An error as the operator should read it: the host's own
    /// developer-facing description for a `LogFileError` (its
    /// `localizedDescription` is the generic Foundation one), otherwise the
    /// system's localized description.
    ///
    /// - Parameter error: The error.
    /// - Returns: The reason to show and record.
    private static func reason(for error: any Error) -> String {
        if let error = error as? LogFileError { return error.description }
        return error.localizedDescription
    }
}
