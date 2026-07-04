//
//  OSLogAttachmentTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraEventBus

@testable import TingraCLI

@Suite("OSLogAttachment")
struct OSLogAttachmentTests {
    @Test("attaches when standard error is not a terminal — the system of record for non-interactive runs")
    func attachesWhenNotATerminal() async {
        let eventBus = EventBus()

        let task = OSLogAttachment.attachIfNeeded(to: eventBus, isStandardErrorATerminal: { false })

        #expect(task != nil)
        eventBus.shutdown()
        await task?.value
    }

    @Test("skips attaching when standard error is a terminal — the OS mirror already echoes it there")
    func skipsWhenATerminal() {
        let eventBus = EventBus()

        let task = OSLogAttachment.attachIfNeeded(to: eventBus, isStandardErrorATerminal: { true })

        #expect(task == nil)
        eventBus.shutdown()
    }
}
