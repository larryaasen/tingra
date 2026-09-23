//
//  ProgramOutputTools.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// What the program's stream and recording tools act on — the engine model,
/// behind a seam so the tools are tested against a fake with no engine
/// booted, as ``ProgramControlling`` is for the switcher's tools.
@MainActor
protocol ProgramOutputControlling: AnyObject, Sendable {
    /// The stream's live state.
    var streamStatus: EngineModel.StreamStatus { get }

    /// Whether a stream is starting, live, or reconnecting.
    var isStreaming: Bool { get }

    /// Whether the project has an enabled destination with a usable URL.
    var hasStreamableDestination: Bool { get }

    /// The recording's live state.
    var recordingStatus: EngineModel.RecordingStatus { get }

    /// Whether a recording is starting or writing.
    var isRecording: Bool { get }

    /// Where the current recording is being written, if one is.
    var recordingURL: URL? { get }

    /// Puts the program on air to the project's enabled destinations.
    func startStreaming() async

    /// Takes the program off air.
    func stopStreaming() async

    /// Starts recording the program to the recordings folder.
    func startRecording() async

    /// Stops the recording, finalizing the file.
    func stopRecording() async
}

/// What the four tools share: the empty argument schema, and the results —
/// the same `stream` and `recording` state members `tingra://session`
/// renders (``EngineResources``), so a caller reads one shape from the call
/// and from the resource it then follows.
nonisolated enum ProgramOutputTool {
    /// The JSON Schema of a tool that takes no arguments: the project's
    /// enabled destinations and the program are what the tools act on
    /// (PLUGINS.md, Decision 17).
    static let noArguments: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    /// A stream tool's result: the stream's state now, and whether this
    /// call is what changed it.
    @MainActor
    static func streamResult(of outputs: any ProgramOutputControlling, changed: Bool) -> JSONValue {
        .object(["stream": .object(EngineResources.streamState(outputs.streamStatus)), "changed": .bool(changed)])
    }

    /// A recording tool's result: the recording's state now, with the
    /// file's path while there is one, and whether this call is what
    /// changed it.
    ///
    /// - Parameters:
    ///   - outputs: The outputs the state is read from.
    ///   - changed: Whether this call changed the state.
    ///   - file: The file to name when the model no longer does — the one
    ///     a stop just closed.
    @MainActor
    static func recordingResult(
        of outputs: any ProgramOutputControlling, changed: Bool, file: URL? = nil
    ) -> JSONValue {
        var recording = EngineResources.recordingState(outputs.recordingStatus)
        if let url = outputs.recordingURL ?? file { recording["path"] = .string(url.path(percentEncoded: false)) }
        return .object(["recording": .object(recording), "changed": .bool(changed)])
    }
}

/// The `program_stream_start` tool: puts the program on air to the
/// project's enabled destinations — the toolbar's Start Streaming, with the
/// stream keys read from secure storage by the model exactly as the button's
/// are, so no key is ever an argument. App-owned, with a name of its own:
/// the daemon's `stream_start` takes an input and destinations, and one tool
/// name never carries two schemas (PLUGINS.md, Decision 17).
nonisolated struct ProgramStreamStartTool: Tool {
    /// The outputs the tool acts on.
    private let outputs: any ProgramOutputControlling

    /// Creates the tool.
    init(outputs: any ProgramOutputControlling) {
        self.outputs = outputs
    }

    let name = "program_stream_start"
    let title = "Start Streaming the Program"
    let description =
        "Put the program on air: stream it to every enabled destination of the open project, with the stream keys "
        + "the operator stored. Takes no arguments. Returns once the stream is starting — 'stream.state' — not "
        + "once it is live: follow tingra://session for 'live', a reconnect, or a destination that refused. "
        + "Already streaming is not an error; 'changed' is false."
    let inputSchema = ProgramOutputTool.noArguments

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        guard await !outputs.isStreaming else {
            return await ProgramOutputTool.streamResult(of: outputs, changed: false)
        }
        guard await outputs.hasStreamableDestination else {
            throw ToolError(
                identifier: .destinationNotFound,
                message:
                    "The open project has no enabled destination with an rtmp://, rtmps://, or srt:// URL. Add or "
                    + "enable one in the app's Streaming settings; tingra://session lists the destinations.")
        }
        await outputs.startStreaming()
        if case .error(let message) = await outputs.streamStatus {
            throw ToolError(identifier: .pipelineError, message: message)
        }
        return await ProgramOutputTool.streamResult(of: outputs, changed: true)
    }
}

/// The `program_stream_stop` tool: takes the program off air — the
/// toolbar's Stop Streaming. A recording in flight keeps rolling; the two
/// sessions are independent (ARCHITECTURE.md, "Recording in the app").
nonisolated struct ProgramStreamStopTool: Tool {
    /// The outputs the tool acts on.
    private let outputs: any ProgramOutputControlling

    /// Creates the tool.
    init(outputs: any ProgramOutputControlling) {
        self.outputs = outputs
    }

    let name = "program_stream_stop"
    let title = "Stop Streaming the Program"
    let description =
        "Take the program off air: a clean stop of the stream to every destination. Takes no arguments. A "
        + "recording in flight keeps rolling. Not streaming is not an error; 'changed' is false. Returns "
        + "'stream.state'; follow tingra://session for 'stopped'."
    let inputSchema = ProgramOutputTool.noArguments

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        guard await outputs.isStreaming else {
            return await ProgramOutputTool.streamResult(of: outputs, changed: false)
        }
        await outputs.stopStreaming()
        return await ProgramOutputTool.streamResult(of: outputs, changed: true)
    }
}

/// The `program_record_start` tool: records the program to a new file in
/// the operator's recordings folder, in the container they chose — the
/// toolbar's Record. Where the file goes is the operator's setting, never
/// an argument: a plug-in does not get to write where it likes.
nonisolated struct ProgramRecordStartTool: Tool {
    /// The outputs the tool acts on.
    private let outputs: any ProgramOutputControlling

    /// Creates the tool.
    init(outputs: any ProgramOutputControlling) {
        self.outputs = outputs
    }

    let name = "program_record_start"
    let title = "Start Recording the Program"
    let description =
        "Record the program to a new file in the operator's recordings folder, in the container chosen in the "
        + "app's Recording settings. Takes no arguments. Independent of streaming. Returns 'recording.state' and "
        + "the file's 'path'; follow tingra://session for 'recording'. Already recording is not an error; "
        + "'changed' is false."
    let inputSchema = ProgramOutputTool.noArguments

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        guard await !outputs.isRecording else {
            return await ProgramOutputTool.recordingResult(of: outputs, changed: false)
        }
        await outputs.startRecording()
        if case .error(let message) = await outputs.recordingStatus {
            throw ToolError(identifier: .recordingFailed, message: message)
        }
        return await ProgramOutputTool.recordingResult(of: outputs, changed: true)
    }
}

/// The `program_record_stop` tool: stops the recording and finalizes the
/// file so it is playable — the toolbar's Stop Recording. A stream in
/// flight stays on air.
nonisolated struct ProgramRecordStopTool: Tool {
    /// The outputs the tool acts on.
    private let outputs: any ProgramOutputControlling

    /// Creates the tool.
    init(outputs: any ProgramOutputControlling) {
        self.outputs = outputs
    }

    let name = "program_record_stop"
    let title = "Stop Recording the Program"
    let description =
        "Stop recording the program and finalize the file so it is playable. Takes no arguments. A stream in "
        + "flight stays on air. Not recording is not an error; 'changed' is false. Returns 'recording.state' — "
        + "'finalizing' while the file closes — and the file's 'path'; follow tingra://session for 'idle'."
    let inputSchema = ProgramOutputTool.noArguments

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        guard await outputs.isRecording else {
            return await ProgramOutputTool.recordingResult(of: outputs, changed: false)
        }
        // The path is read before the stop: the model forgets it once the
        // file is closed, and the caller is owed the name of what it made.
        let url = await outputs.recordingURL
        await outputs.stopRecording()
        return await ProgramOutputTool.recordingResult(of: outputs, changed: true, file: url)
    }
}
