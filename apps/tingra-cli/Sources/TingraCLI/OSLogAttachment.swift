//
//  OSLogAttachment.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus
import TingraHost

/// Whether `OSLogSink` should be attached for this run (see EVENTS.md,
/// "OSLog sink").
///
/// When standard error is a terminal, macOS's own unified-logging terminal
/// mirror already echoes this process's `os_log` traffic to it — attaching
/// the sink would print every event a second time, interleaved with the
/// console sink's formatted lines. Skipping it there is silent for
/// interactive runs (the console sink already told the human everything);
/// OSLog remains the system of record for every non-interactive context
/// (scripts, launchd, redirected or piped output, `--json` consumers) where
/// the terminal mirror does not run.
enum OSLogAttachment {
    /// Attaches `OSLogSink` to `eventBus` unless standard error is a
    /// terminal, returning the sink's task, or nil when skipped.
    ///
    /// - Parameter isStandardErrorATerminal: The terminal check; defaults
    ///   to the real file descriptor, injected so tests can force either
    ///   branch without touching process state.
    static func attachIfNeeded(
        to eventBus: EventBus,
        isStandardErrorATerminal: @Sendable () -> Bool = { isatty(FileHandle.standardError.fileDescriptor) != 0 }
    ) -> Task<Void, Never>? {
        guard !isStandardErrorATerminal() else { return nil }
        return eventBus.attach(OSLogSink())
    }
}
