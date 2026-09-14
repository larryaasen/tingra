//
//  DebouncedWriterTests.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraPlugInKit

@testable import TingraAppPlugInKit

/// The debounced writer behind a pane's project storage: one write per
/// pause, the last value wins, flush writes now.
@Suite("Debounced writer")
struct DebouncedWriterTests {
    @Test("a burst of values produces one write of the last value after the pause")
    func coalescesBurst() async throws {
        let written = Mutex<[JSONValue]>([])
        let writer = DebouncedWriter(delay: .milliseconds(30)) { value in written.withLock { $0.append(value) } }
        await writer.schedule(.string("a"))
        await writer.schedule(.string("ab"))
        await writer.schedule(.string("abc"))
        try await Task.sleep(for: .milliseconds(120))
        #expect(written.withLock { $0 } == [.string("abc")])
        #expect(await writer.writeCount == 1)
    }

    @Test("flush writes the waiting value immediately and once")
    func flushWritesNow() async throws {
        let written = Mutex<[JSONValue]>([])
        let writer = DebouncedWriter(delay: .seconds(10)) { value in written.withLock { $0.append(value) } }
        await writer.schedule(.int(1))
        await writer.flush()
        #expect(written.withLock { $0 } == [.int(1)])
        await writer.flush()
        #expect(written.withLock { $0 } == [.int(1)])
    }

    @Test("flush with nothing waiting writes nothing")
    func flushWithNothingWaiting() async {
        let written = Mutex<[JSONValue]>([])
        let writer = DebouncedWriter(delay: .milliseconds(1)) { value in written.withLock { $0.append(value) } }
        await writer.flush()
        #expect(written.withLock { $0 }.isEmpty)
    }
}
