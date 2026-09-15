//
//  ProgramToolsTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-09-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraComposition
import TingraEventBus
import TingraHost
import TingraPlugInKit

@testable import TingraApp

/// A program that records what the tools did to it.
@MainActor
private final class FakeProgram: ProgramControlling {
    var shots: [Shot]
    var activeShotID: ShotID?
    var previewShotID: ShotID?
    var isFadedToBlack = false

    /// The fade durations asked for, in order.
    var fadeDurations: [TimeInterval] = []

    /// Creates a program over `shots`.
    init(shots: [Shot]) {
        self.shots = shots
    }

    func take(_ shotID: ShotID) { activeShotID = shotID }
    func setPreview(_ shotID: ShotID) { previewShotID = shotID }
    func setFadeToBlack(_ faded: Bool, duration: TimeInterval) {
        isFadedToBlack = faded
        fadeDurations.append(duration)
    }
}

/// The first-party program tools: the shot selector's rule, the takes and
/// stages they make, fade to black, and the errors an agent branches on —
/// against a fake program, no engine booted.
@Suite("Program tools")
struct ProgramToolsTests {
    /// Three shots: two distinct names and a repeated one.
    private let shots = [
        Shot(id: ShotID(rawValue: "shot-wide"), name: "Wide"),
        Shot(id: ShotID(rawValue: "shot-close"), name: "Close"),
        Shot(id: ShotID(rawValue: "shot-close-2"), name: "close"),
    ]

    @Test("the plug-in registers the three tools")
    func registers() async throws {
        let program = await FakeProgram(shots: shots)
        let tools = ToolRegistry()
        let context = PlugInContext(
            eventBus: EventBus(), clock: HostClock(), inputs: InputRegistry(), outputs: OutputRegistry(),
            effects: EffectRegistry(), tools: tools)
        try await ProgramToolsPlugIn(program: program).activate(in: context)
        #expect(await tools.allTools.map(\.name) == ["shot_take", "preview_set", "fade_to_black"])
        #expect(ProgramToolsPlugIn(program: program).id.rawValue == "com.moonwink.tingra.program")
    }

    @Test("shot_take by id takes the shot and returns it")
    func takesByID() async throws {
        let program = await FakeProgram(shots: shots)
        let result = try await ShotTakeTool(program: program).call(.object(["shot": .string("shot-wide")]))
        #expect(result["shot"]?["id"]?.stringValue == "shot-wide")
        #expect(result["shot"]?["name"]?.stringValue == "Wide")
        #expect(await program.activeShotID?.rawValue == "shot-wide")
        #expect(await program.previewShotID == nil)
    }

    @Test("an exact id wins over a name, and a unique name matches case-insensitively")
    func selectorRule() async throws {
        let program = await FakeProgram(shots: shots + [Shot(id: ShotID(rawValue: "Wide"), name: "Other")])
        let byID = try await PreviewSetTool(program: program).call(.object(["shot": .string("Wide")]))
        #expect(byID["shot"]?["id"]?.stringValue == "Wide")
        let byName = try await PreviewSetTool(program: program).call(.object(["shot": .string("wide")]))
        #expect(byName["shot"]?["id"]?.stringValue == "shot-wide")
        #expect(await program.previewShotID?.rawValue == "shot-wide")
        #expect(await program.activeShotID == nil)
    }

    @Test("a selector matching nothing is shotNotFound and one matching two is shotAmbiguous")
    func selectorErrors() async throws {
        let program = await FakeProgram(shots: shots)
        let tool = ShotTakeTool(program: program)
        await #expect(throws: ToolError.self) {
            try await tool.call(.object(["shot": .string("Tight")]))
        }
        do {
            _ = try await tool.call(.object(["shot": .string("Tight")]))
        } catch let error as ToolError {
            #expect(error.identifier == .shotNotFound)
            #expect(error.message.contains("tingra://program"))
        }
        do {
            _ = try await tool.call(.object(["shot": .string("CLOSE")]))
        } catch let error as ToolError {
            #expect(error.identifier == .shotAmbiguous)
            #expect(error.message.contains("shot-close-2"))
        }
        #expect(await program.activeShotID == nil)
    }

    @Test("a missing, empty, or non-string shot is invalidArgument")
    func missingSelector() async throws {
        let program = await FakeProgram(shots: shots)
        for arguments in [JSONValue.object([:]), .object(["shot": .string("")]), .object(["shot": .int(1)]), .null] {
            do {
                _ = try await ShotTakeTool(program: program).call(arguments)
                Issue.record("\(arguments) should have thrown")
            } catch let error as ToolError {
                #expect(error.identifier == .invalidArgument)
            }
        }
    }

    @Test("fade_to_black fades and restores, with the default and a given duration")
    func fades() async throws {
        let program = await FakeProgram(shots: shots)
        let tool = FadeToBlackTool(program: program)
        let down = try await tool.call(.object(["faded": .bool(true)]))
        #expect(down["fadedToBlack"] == .bool(true))
        let up = try await tool.call(.object(["faded": .bool(false), "duration": .double(1.5)]))
        #expect(up["fadedToBlack"] == .bool(false))
        #expect(await program.fadeDurations == [Transition.defaultDissolveDuration, 1.5])
    }

    @Test("fade_to_black refuses a missing faded and a non-positive duration")
    func fadeErrors() async throws {
        let program = await FakeProgram(shots: shots)
        let tool = FadeToBlackTool(program: program)
        for arguments in [
            JSONValue.object([:]), .object(["faded": .string("yes")]),
            .object(["faded": .bool(true), "duration": .int(0)]),
            .object(["faded": .bool(true), "duration": .string("fast")]),
        ] {
            do {
                _ = try await tool.call(arguments)
                Issue.record("\(arguments) should have thrown")
            } catch let error as ToolError {
                #expect(error.identifier == .invalidArgument)
            }
        }
        #expect(await program.fadeDurations.isEmpty)
    }

    @Test("the tools' schemas require their arguments")
    func schemas() {
        let program = FakeProgram(shots: [])
        #expect(ShotTakeTool(program: program).inputSchema["required"] == .array([.string("shot")]))
        #expect(PreviewSetTool(program: program).inputSchema["required"] == .array([.string("shot")]))
        #expect(FadeToBlackTool(program: program).inputSchema["required"] == .array([.string("faded")]))
    }
}
