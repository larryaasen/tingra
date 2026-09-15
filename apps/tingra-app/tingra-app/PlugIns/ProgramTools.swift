//
//  ProgramTools.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition
import TingraPlugInKit

/// What the program tools act on — the engine model, behind a seam so the
/// tools are tested against a fake with no engine booted. Main-actor
/// isolated like the model; a tool hops there for the length of one call.
@MainActor
protocol ProgramControlling: AnyObject, Sendable {
    /// The active preset's shots, transient ones included.
    var shots: [Shot] { get }

    /// The shot on program, if any.
    var activeShotID: ShotID? { get }

    /// The shot staged on preview, if any.
    var previewShotID: ShotID? { get }

    /// Whether the program is faded to black.
    var isFadedToBlack: Bool { get }

    /// Takes a shot to program.
    func take(_ shotID: ShotID)

    /// Stages a shot on preview.
    func setPreview(_ shotID: ShotID)

    /// Fades the program to black, or brings it back, over `duration`.
    func setFadeToBlack(_ faded: Bool, duration: TimeInterval)
}

/// The first-party program tools plug-in: the controls a plug-in or an agent
/// acts on the program with — `shot_take`, `preview_set`, `fade_to_black` —
/// registered through the same `ToolRegistering` seam every tool plug-in
/// uses (PLUGINS.md, Decision 10: plug-ins control the engine through the
/// MCP tools, never a parallel API). App-owned rather than in `TingraMCP`
/// because only the app has a program: the daemon streams a single input
/// through `StreamSession` and has no compositor to take a shot on.
nonisolated struct ProgramToolsPlugIn: PlugIn {
    let id = PlugInID(rawValue: "com.moonwink.tingra.program")
    let name = "Program Tools"

    /// The program the tools act on.
    private let program: any ProgramControlling

    /// Creates the plug-in over a program.
    ///
    /// - Parameter program: The program the tools act on.
    init(program: any ProgramControlling) {
        self.program = program
    }

    func activate(in context: PlugInContext) async throws {
        try await context.tools.register(ShotTakeTool(program: program))
        try await context.tools.register(PreviewSetTool(program: program))
        try await context.tools.register(FadeToBlackTool(program: program))
    }
}

/// Resolves the `shot` selector the program tools share, on the rule the
/// input and destination selectors already teach (MCP.md, "Tool surface"):
/// an exact id wins outright; otherwise a case-insensitive name that must
/// match exactly one shot. No index form — a switcher position is not
/// stable across an edit.
nonisolated enum ShotSelector {
    /// The JSON Schema for the `shot` argument, shared by the two tools.
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "shot": .object([
                "type": .string("string"),
                "description": .string(
                    "The shot, by id or by name: an exact id wins; otherwise a case-insensitive name that matches "
                        + "exactly one shot of the active preset. Read tingra://program for the shots and their ids."),
            ])
        ]),
        "required": .array([.string("shot")]),
    ])

    /// The selector a tool call carries.
    ///
    /// - Parameters:
    ///   - arguments: The call's arguments.
    ///   - tool: The tool's name, for the message.
    /// - Throws: `invalidArgument` for a missing, non-string, or empty `shot`.
    static func selector(in arguments: JSONValue, tool: String) throws -> String {
        guard let selector = arguments["shot"]?.stringValue, !selector.isEmpty else {
            throw ToolError(
                identifier: .invalidArgument,
                message: "\(tool) requires 'shot', the id or name of a shot of the active preset.")
        }
        return selector
    }

    /// The shot a selector names.
    ///
    /// - Parameters:
    ///   - selector: The id or name.
    ///   - shots: The active preset's shots.
    /// - Throws: `shotNotFound` when nothing matches, `shotAmbiguous` when
    ///   a name matches more than one shot.
    static func resolve(_ selector: String, in shots: [Shot]) throws -> Shot {
        if let byID = shots.first(where: { $0.id.rawValue == selector }) { return byID }
        let byName = shots.filter { $0.name.caseInsensitiveCompare(selector) == .orderedSame }
        switch byName.count {
        case 1:
            return byName[0]
        case 0:
            throw ToolError(
                identifier: .shotNotFound,
                message:
                    "No shot of the active preset has the id or name '\(selector)'. Read tingra://program for the "
                    + "shots and their ids.")
        default:
            let matches = byName.map { "'\($0.name)' (\($0.id.rawValue))" }.joined(separator: ", ")
            throw ToolError(
                identifier: .shotAmbiguous,
                message: "'\(selector)' names \(byName.count) shots: \(matches). Use the id.")
        }
    }

    /// The result the two tools return: the shot acted on.
    static func result(for shot: Shot) -> JSONValue {
        .object(["shot": .object(["id": .string(shot.id.rawValue), "name": .string(shot.name)])])
    }
}

/// The `shot_take` tool: takes a shot of the active preset to program with
/// the switcher's selected transition — the same take the operator's click
/// makes, so the compositor's `program.take` event reports it.
nonisolated struct ShotTakeTool: Tool {
    /// The program the tool acts on.
    private let program: any ProgramControlling

    /// Creates the tool.
    init(program: any ProgramControlling) {
        self.program = program
    }

    let name = "shot_take"
    let title = "Take Shot"
    let description =
        "Take a shot of the active preset to program, with the switcher's selected transition. Names the shot by "
        + "id or by name; read tingra://program for the shots, their ids, and what is on program now."
    let inputSchema = ShotSelector.schema

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        let selector = try ShotSelector.selector(in: arguments, tool: name)
        return try await MainActor.run {
            let shot = try ShotSelector.resolve(selector, in: program.shots)
            program.take(shot.id)
            return ShotSelector.result(for: shot)
        }
    }
}

/// The `preview_set` tool: stages a shot of the active preset on preview,
/// the staging bus, leaving program untouched.
nonisolated struct PreviewSetTool: Tool {
    /// The program the tool acts on.
    private let program: any ProgramControlling

    /// Creates the tool.
    init(program: any ProgramControlling) {
        self.program = program
    }

    let name = "preview_set"
    let title = "Stage on Preview"
    let description =
        "Stage a shot of the active preset on preview, where it is composed and checked before a take; program is "
        + "untouched. Names the shot by id or by name; read tingra://program for the shots and their ids."
    let inputSchema = ShotSelector.schema

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        let selector = try ShotSelector.selector(in: arguments, tool: name)
        return try await MainActor.run {
            let shot = try ShotSelector.resolve(selector, in: program.shots)
            program.setPreview(shot.id)
            return ShotSelector.result(for: shot)
        }
    }
}

/// The `fade_to_black` tool: takes the program — picture and sound — down
/// to black, or brings it back, over a ramp (GLOSSARY.md, "Fade to black").
nonisolated struct FadeToBlackTool: Tool {
    /// The program the tool acts on.
    private let program: any ProgramControlling

    /// Creates the tool.
    init(program: any ProgramControlling) {
        self.program = program
    }

    let name = "fade_to_black"
    let title = "Fade to Black"
    let description =
        "Fade the program — picture and sound — to black, or bring it back up: 'faded' true takes it down, false "
        + "brings it back. 'duration' is the ramp in seconds (default half a second). Every destination and any "
        + "recording carry the fade; preview and the meters stay live. Returns 'fadedToBlack'."
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "faded": .object([
                "type": .string("boolean"),
                "description": .string("true to fade the program to black, false to bring it back."),
            ]),
            "duration": .object([
                "type": .string("number"),
                "description": .string("The ramp length in seconds, greater than zero (default 0.5)."),
            ]),
        ]),
        "required": .array([.string("faded")]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        guard let faded = arguments["faded"]?.boolValue else {
            throw ToolError(identifier: .invalidArgument, message: "fade_to_black requires 'faded', true or false.")
        }
        var duration = Transition.defaultDissolveDuration
        if let given = arguments["duration"] {
            guard let seconds = given.doubleValue, seconds.isFinite, seconds > 0 else {
                throw ToolError(
                    identifier: .invalidArgument,
                    message: "fade_to_black's 'duration' must be a number of seconds greater than zero.")
            }
            duration = seconds
        }
        return await MainActor.run {
            program.setFadeToBlack(faded, duration: duration)
            return .object(["fadedToBlack": .bool(program.isFadedToBlack)])
        }
    }
}
