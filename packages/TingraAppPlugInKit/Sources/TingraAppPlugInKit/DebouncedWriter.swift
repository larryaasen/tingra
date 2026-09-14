//
//  DebouncedWriter.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Coalesces a stream of values into one write after the stream pauses: a
/// text editor's keystrokes become one project-storage write per pause,
/// not one per key, so the document is dirtied and saved at typing's
/// natural rate (PLUGINS.md, Notes: `notes.edited` is debounced).
///
/// The last value scheduled wins; ``flush()`` writes it immediately, for a
/// pane about to disappear.
public actor DebouncedWriter {
    /// Performs the write.
    public typealias Write = @Sendable (JSONValue) async -> Void

    /// How long the stream must pause before a write.
    private let delay: Duration

    /// The clock the pause is measured on (a test clock under test).
    private let clock: any Clock<Duration>

    /// Performs the write.
    private let write: Write

    /// The value waiting to be written, if any.
    private var waiting: JSONValue?

    /// The pause timer, while a value waits.
    private var timer: Task<Void, Never>?

    /// How many writes have been performed.
    public private(set) var writeCount = 0

    /// Creates a writer.
    ///
    /// - Parameters:
    ///   - delay: How long the stream must pause before a write.
    ///   - clock: The clock the pause is measured on.
    ///   - write: Performs the write.
    public init(delay: Duration, clock: any Clock<Duration> = ContinuousClock(), write: @escaping Write) {
        self.delay = delay
        self.clock = clock
        self.write = write
    }

    /// Schedules `value` to be written once the stream pauses, replacing
    /// any value already waiting.
    ///
    /// - Parameter value: The value to write.
    public func schedule(_ value: JSONValue) {
        waiting = value
        timer?.cancel()
        timer = Task { [delay, clock] in
            try? await clock.sleep(for: delay, tolerance: nil)
            guard !Task.isCancelled else { return }
            await self.fire()
        }
    }

    /// Writes the waiting value now, if there is one.
    public func flush() async {
        timer?.cancel()
        timer = nil
        await fire()
    }

    /// Writes the waiting value, if any.
    private func fire() async {
        guard let value = waiting else { return }
        waiting = nil
        writeCount += 1
        await write(value)
    }
}
