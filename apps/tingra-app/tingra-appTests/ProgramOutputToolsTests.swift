//
//  ProgramOutputToolsTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraPlugInKit

@testable import TingraApp

/// A stream and a recording that record what the tools did to them, and
/// settle the way the model does: a start goes to `starting` — or to the
/// scripted error — and a stop to `stopped` or `finalizing`.
@MainActor
final class FakeProgramOutputs: ProgramOutputControlling {
    var streamStatus: EngineModel.StreamStatus = .idle
    var recordingStatus: EngineModel.RecordingStatus = .idle
    var hasStreamableDestination = true
    var recordingURL: URL?

    /// The error a stream start settles on, or nil for `starting`.
    var streamStartError: String?

    /// The error a recording start settles on, or nil for `starting`.
    var recordingStartError: String?

    /// The calls made, in order.
    var calls: [String] = []

    /// Creates idle outputs.
    init() {}

    var isStreaming: Bool {
        switch streamStatus {
        case .starting, .live, .reconnecting: true
        case .idle, .stopped, .error: false
        }
    }

    var isRecording: Bool {
        switch recordingStatus {
        case .starting, .recording: true
        case .idle, .finalizing, .error: false
        }
    }

    func startStreaming() async {
        calls.append("startStreaming")
        streamStatus = streamStartError.map(EngineModel.StreamStatus.error) ?? .starting
    }

    func stopStreaming() async {
        calls.append("stopStreaming")
        streamStatus = .stopped
    }

    func startRecording() async {
        calls.append("startRecording")
        if let recordingStartError {
            recordingStatus = .error(recordingStartError)
        } else {
            recordingStatus = .starting
            recordingURL = URL(filePath: "/tmp/Recordings/Tingra 2026-09-18 at 09.00.00.mov")
        }
    }

    func stopRecording() async {
        calls.append("stopRecording")
        recordingStatus = .finalizing
        // The model forgets the file once it is closed; the tool must not.
        recordingURL = nil
    }
}

/// The app-owned stream and recording tools (PLUGINS.md, Decision 17): what
/// each does to the outputs, what it answers, and the errors an agent
/// branches on — against fake outputs, no engine booted.
@Suite("Program output tools")
struct ProgramOutputToolsTests {
    /// The arguments every one of the four tools takes: none.
    private let none = JSONValue.object([:])

    @Test("program_stream_start starts the stream and answers starting, changed")
    func startsStreaming() async throws {
        let outputs = FakeProgramOutputs()
        let result = try await ProgramStreamStartTool(outputs: outputs).call(none)
        #expect(result["stream"]?["state"]?.stringValue == "starting")
        #expect(result["changed"]?.boolValue == true)
        #expect(outputs.calls == ["startStreaming"])
    }

    @Test("program_stream_start while on air starts nothing and answers the state, unchanged")
    func startWhileStreamingIsUnchanged() async throws {
        let outputs = FakeProgramOutputs()
        outputs.streamStatus = .reconnecting(attempt: 2, maxAttempts: 5)
        let result = try await ProgramStreamStartTool(outputs: outputs).call(none)
        #expect(result["stream"]?["state"]?.stringValue == "reconnecting")
        #expect(result["stream"]?["attempt"]?.intValue == 2)
        #expect(result["stream"]?["maxAttempts"]?.intValue == 5)
        #expect(result["changed"]?.boolValue == false)
        #expect(outputs.calls.isEmpty)
    }

    @Test("program_stream_start with no streamable destination returns destinationNotFound and starts nothing")
    func startWithoutDestinationThrows() async throws {
        let outputs = FakeProgramOutputs()
        outputs.hasStreamableDestination = false
        do {
            _ = try await ProgramStreamStartTool(outputs: outputs).call(none)
            Issue.record("a start with nothing to stream to should throw")
        } catch let error as ToolError {
            #expect(error.identifier == .destinationNotFound)
            #expect(error.message.contains("Streaming settings"))
        }
        #expect(outputs.calls.isEmpty)
    }

    @Test("a stream start that settles on an error returns pipelineError with the model's message")
    func startErrorThrows() async throws {
        let outputs = FakeProgramOutputs()
        outputs.streamStartError = "No streaming output serves ftp destinations."
        do {
            _ = try await ProgramStreamStartTool(outputs: outputs).call(none)
            Issue.record("a start that settled on an error should throw")
        } catch let error as ToolError {
            #expect(error.identifier == .pipelineError)
            #expect(error.message == "No streaming output serves ftp destinations.")
        }
    }

    @Test("program_stream_stop stops a live stream, and off air it answers the state, unchanged")
    func stopsStreaming() async throws {
        let outputs = FakeProgramOutputs()
        let idle = try await ProgramStreamStopTool(outputs: outputs).call(none)
        #expect(idle["stream"]?["state"]?.stringValue == "idle")
        #expect(idle["changed"]?.boolValue == false)
        #expect(outputs.calls.isEmpty)
        outputs.streamStatus = .live
        let stopped = try await ProgramStreamStopTool(outputs: outputs).call(none)
        #expect(stopped["stream"]?["state"]?.stringValue == "stopped")
        #expect(stopped["changed"]?.boolValue == true)
        #expect(outputs.calls == ["stopStreaming"])
    }

    @Test("program_record_start starts the recording and names the file")
    func startsRecording() async throws {
        let outputs = FakeProgramOutputs()
        let result = try await ProgramRecordStartTool(outputs: outputs).call(none)
        #expect(result["recording"]?["state"]?.stringValue == "starting")
        #expect(result["recording"]?["path"]?.stringValue == "/tmp/Recordings/Tingra 2026-09-18 at 09.00.00.mov")
        #expect(result["changed"]?.boolValue == true)
        let again = try await ProgramRecordStartTool(outputs: outputs).call(none)
        #expect(again["changed"]?.boolValue == false)
        #expect(outputs.calls == ["startRecording"])
    }

    @Test("a recording start that settles on an error returns recordingFailed with the model's message")
    func recordStartErrorThrows() async throws {
        let outputs = FakeProgramOutputs()
        outputs.recordingStartError = "The recordings folder could not be created."
        do {
            _ = try await ProgramRecordStartTool(outputs: outputs).call(none)
            Issue.record("a recording that could not open should throw")
        } catch let error as ToolError {
            #expect(error.identifier == .recordingFailed)
            #expect(error.message == "The recordings folder could not be created.")
        }
    }

    @Test("program_record_stop finalizes and still names the file the model has let go of")
    func stopsRecording() async throws {
        let outputs = FakeProgramOutputs()
        let idle = try await ProgramRecordStopTool(outputs: outputs).call(none)
        #expect(idle["recording"]?["state"]?.stringValue == "idle")
        #expect(idle["recording"]?["path"] == nil)
        #expect(idle["changed"]?.boolValue == false)
        _ = try await ProgramRecordStartTool(outputs: outputs).call(none)
        outputs.recordingStatus = .recording
        let stopped = try await ProgramRecordStopTool(outputs: outputs).call(none)
        #expect(stopped["recording"]?["state"]?.stringValue == "finalizing")
        #expect(stopped["recording"]?["path"]?.stringValue == "/tmp/Recordings/Tingra 2026-09-18 at 09.00.00.mov")
        #expect(stopped["changed"]?.boolValue == true)
        #expect(outputs.calls == ["startRecording", "stopRecording"])
    }

    @Test("stopping the stream leaves a recording alone, and the other way round")
    func outputsAreIndependent() async throws {
        let outputs = FakeProgramOutputs()
        outputs.streamStatus = .live
        outputs.recordingStatus = .recording
        _ = try await ProgramStreamStopTool(outputs: outputs).call(none)
        #expect(outputs.recordingStatus == .recording)
        outputs.streamStatus = .live
        _ = try await ProgramRecordStopTool(outputs: outputs).call(none)
        #expect(outputs.streamStatus == .live)
    }

    @Test("the four tools take no arguments and carry distinct names")
    func schemas() {
        let outputs = FakeProgramOutputs()
        let tools: [any Tool] = [
            ProgramStreamStartTool(outputs: outputs), ProgramStreamStopTool(outputs: outputs),
            ProgramRecordStartTool(outputs: outputs), ProgramRecordStopTool(outputs: outputs),
        ]
        for tool in tools {
            #expect(tool.inputSchema["type"]?.stringValue == "object")
            #expect(tool.inputSchema["required"] == nil)
            #expect(tool.name.hasPrefix("program_"))
        }
        #expect(Set(tools.map(\.name)).count == 4)
    }

    @Test("the state renderers carry a reconnect's counters and an error's message")
    func stateRenderers() {
        #expect(EngineResources.streamState(.live) == ["state": .string("live")])
        #expect(
            EngineResources.streamState(.error("refused")) == [
                "state": .string("error"), "message": .string("refused"),
            ]
        )
        #expect(EngineResources.recordingState(.finalizing) == ["state": .string("finalizing")])
        #expect(EngineResources.recordingState(.idle) != EngineResources.recordingState(.recording))
    }
}
