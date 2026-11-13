//
//  ApplicationAudioErrorTests.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApplicationAudio

/// The errors' descriptions and the guard that runs before any Core Audio
/// call.
@Suite("ApplicationAudioError")
struct ApplicationAudioErrorTests {
    @Test("Each description names the status Core Audio returned")
    func descriptionsCarryStatus() {
        let errors: [ApplicationAudioError] = [
            .processListUnavailable(status: -50), .tapRejected(status: -50), .aggregateRejected(status: -50),
            .ioProcRejected(status: -50), .startRejected(status: -50),
        ]
        for error in errors {
            #expect(error.description.contains("-50"))
        }
        #expect(ApplicationAudioError.unsupportedFormat("16-bit").description.contains("16-bit"))
        #expect(!ApplicationAudioError.noProcesses.description.isEmpty)
    }

    @Test("Equal errors compare equal and differing ones do not")
    func equality() {
        #expect(ApplicationAudioError.tapRejected(status: 1) == .tapRejected(status: 1))
        #expect(ApplicationAudioError.tapRejected(status: 1) != .tapRejected(status: 2))
        #expect(ApplicationAudioError.tapRejected(status: 1) != .startRejected(status: 1))
    }

    @Test("A tap over no processes throws before touching Core Audio")
    func noProcessesThrows() {
        #expect(throws: ApplicationAudioError.noProcesses) {
            _ = try ProcessTap.start(processes: [], mutesProcesses: true, name: "Test") { _ in }
        }
    }
}
