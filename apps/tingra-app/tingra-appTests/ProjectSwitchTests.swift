//
//  ProjectSwitchTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApp

/// Exercises the rule behind the File menu's disabled items and the
/// model's refusal to replace the open project (ARCHITECTURE.md, "Projects
/// as documents").
@Suite("ProjectSwitch")
struct ProjectSwitchTests {
    @Test("replacing the project is allowed while nothing is on air")
    func allowedWhenIdle() {
        #expect(ProjectSwitch.refusal(isStreaming: false, isRecording: false) == nil)
    }

    @Test("replacing the project is refused while streaming, naming streaming as the reason")
    func refusedWhileStreaming() {
        #expect(ProjectSwitch.refusal(isStreaming: true, isRecording: false) == "streaming")
    }

    @Test("replacing the project is refused while recording, naming recording as the reason")
    func refusedWhileRecording() {
        #expect(ProjectSwitch.refusal(isStreaming: false, isRecording: true) == "recording")
    }

    @Test("streaming is named first when both are on air")
    func streamingWinsWhenBoth() {
        #expect(ProjectSwitch.refusal(isStreaming: true, isRecording: true) == "streaming")
    }
}
