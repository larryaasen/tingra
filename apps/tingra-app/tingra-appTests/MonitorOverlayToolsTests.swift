//
//  MonitorOverlayToolsTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraEventBus
import TingraHost
import TingraMonitorPlugIns
import TingraPlugInKit

@testable import TingraApp

/// Monitors that record what the tool did to them, over the first-party
/// overlays.
@MainActor
private final class FakeMonitors: MonitorOverlayControlling {
    let monitorOverlayCatalog: MonitorOverlayCatalog

    /// The overlays on each monitor.
    var lists: [MonitorOverlayTarget: [MonitorOverlayID]] = [:]

    /// Creates monitors over a catalog.
    init(catalog: MonitorOverlayCatalog) {
        monitorOverlayCatalog = catalog
    }

    func monitorOverlayIDs(on target: MonitorOverlayTarget) -> [MonitorOverlayID] {
        lists[target] ?? []
    }

    func isMonitorOverlayAvailable(_ provider: any MonitorOverlayProvider, on target: MonitorOverlayTarget) -> Bool {
        provider.isAvailable(on: target.monitor)
    }

    func setMonitorOverlay(_ id: MonitorOverlayID, on target: MonitorOverlayTarget, isOn: Bool) {
        var list = lists[target] ?? []
        list.removeAll { $0 == id }
        if isOn { list.append(id) }
        lists[target] = list
    }
}

/// A third-party overlay with a chosen id and name and nothing to draw.
private struct NamedProvider: MonitorOverlayProvider {
    /// The overlay's identifier.
    let id: MonitorOverlayID

    /// The overlay's name.
    let name: String

    /// A guide.
    let stage = MonitorOverlayStage.guide

    /// No settings.
    var parameters: [Parameter] { [] }

    /// Makes Show Alpha's overlay, which is never drawn here.
    func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        ShowAlphaOverlayProvider().makeOverlay(parameters: parameters)
    }
}

/// `monitor_overlay_set`: the selector rule, the state-not-toggle result,
/// and the errors an agent branches on, against fake monitors with no
/// engine booted.
@Suite("Monitor overlay tools")
@MainActor
struct MonitorOverlayToolsTests {
    /// Fake monitors over every first-party overlay.
    private func makeMonitors() -> FakeMonitors {
        let providers: [any MonitorOverlayProvider] = [
            TallyBorderOverlayProvider(), SafeAreaOverlayProvider.titleSafe, ShowAlphaOverlayProvider(),
            VUMetersOverlayProvider(),
        ]
        return FakeMonitors(catalog: MonitorOverlayCatalog(providers: providers))
    }

    @Test("the plug-in registers monitor_overlay_set")
    func registers() async throws {
        let tools = ToolRegistry()
        let context = PlugInContext(
            eventBus: EventBus(), clock: HostClock(), inputs: InputRegistry(), outputs: OutputRegistry(),
            effects: EffectRegistry(), tools: tools)
        let plugIn = MonitorOverlayToolsPlugIn(overlays: makeMonitors())
        try await plugIn.activate(in: context)
        #expect(await tools.allTools.map(\.name) == ["monitor_overlay_set"])
        #expect(plugIn.id.rawValue == "com.moonwink.tingra.monitorOverlayTools")
    }

    @Test("turning an overlay on by name reports it changed, and again reports no change")
    func turnsOnByName() async throws {
        let monitors = makeMonitors()
        let tool = MonitorOverlaySetTool(overlays: monitors)
        let arguments: JSONValue = .object([
            "monitor": .string("program"), "overlay": .string("title safe"), "on": .bool(true),
        ])
        let first = try await tool.call(arguments)
        #expect(first["overlay"]?["id"]?.stringValue == "titleSafe")
        #expect(first["on"]?.boolValue == true)
        #expect(first["changed"]?.boolValue == true)
        #expect(first["overlays"] == .array([.string("titleSafe")]))
        let second = try await tool.call(arguments)
        #expect(second["changed"]?.boolValue == false)
        #expect(monitors.lists[.program] == [SafeAreaOverlayProvider.titleSafeID])
    }

    @Test("turning an overlay off by id removes it from that monitor only")
    func turnsOffByID() async throws {
        let monitors = makeMonitors()
        monitors.lists = [.input: [ShowAlphaOverlayProvider.overlayID], .layer: [ShowAlphaOverlayProvider.overlayID]]
        let result = try await MonitorOverlaySetTool(overlays: monitors).call(
            .object(["monitor": .string("input"), "overlay": .string("showAlpha"), "on": .bool(false)]))
        #expect(result["changed"]?.boolValue == true)
        #expect(result["overlays"] == .array([]))
        #expect(monitors.lists[.layer] == [ShowAlphaOverlayProvider.overlayID])
    }

    @Test("an overlay with nothing to show on the monitor is not turned on, but can be turned off")
    func unavailableOverlay() async throws {
        let monitors = makeMonitors()
        let tool = MonitorOverlaySetTool(overlays: monitors)
        do {
            _ = try await tool.call(
                .object(["monitor": .string("program"), "overlay": .string("showAlpha"), "on": .bool(true)]))
            Issue.record("Show Alpha on program should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .invalidArgument)
            #expect(error.message.contains("Show Alpha"))
        }
        #expect(monitors.lists[.program] == nil)
        let off = try await tool.call(
            .object(["monitor": .string("preview"), "overlay": .string("vuMeters"), "on": .bool(false)]))
        #expect(off["changed"]?.boolValue == false)
    }

    @Test("an unknown overlay is monitorOverlayNotFound and lists every overlay")
    func unknownOverlay() async throws {
        let tool = MonitorOverlaySetTool(overlays: makeMonitors())
        do {
            _ = try await tool.call(
                .object(["monitor": .string("program"), "overlay": .string("Lower Third"), "on": .bool(true)]))
            Issue.record("an unknown overlay should have thrown")
        } catch let error as ToolError {
            #expect(error.identifier == .monitorOverlayNotFound)
            #expect(error.message.contains("'Title Safe' (titleSafe)"))
        }
    }

    @Test("a name two overlays share is monitorOverlayNotFound, asking for the id")
    func ambiguousName() throws {
        let providers: [any MonitorOverlayProvider] = [
            SafeAreaOverlayProvider.titleSafe,
            NamedProvider(id: MonitorOverlayID(rawValue: "com.example.titleSafe"), name: "Title Safe"),
        ]
        #expect(throws: ToolError.self) {
            try MonitorOverlaySetTool.resolve("title safe", in: providers)
        }
        #expect(
            try MonitorOverlaySetTool.resolve("com.example.titleSafe", in: providers).id.rawValue
                == "com.example.titleSafe")
    }

    @Test("a missing or wrong monitor, overlay, or on is invalidArgument")
    func invalidArguments() async throws {
        let tool = MonitorOverlaySetTool(overlays: makeMonitors())
        let cases: [JSONValue] = [
            .object(["overlay": .string("titleSafe"), "on": .bool(true)]),
            .object(["monitor": .string("multiview"), "overlay": .string("titleSafe"), "on": .bool(true)]),
            .object(["monitor": .string("program"), "on": .bool(true)]),
            .object(["monitor": .string("program"), "overlay": .string(""), "on": .bool(true)]),
            .object(["monitor": .string("program"), "overlay": .string("titleSafe")]),
            .null,
        ]
        for arguments in cases {
            do {
                _ = try await tool.call(arguments)
                Issue.record("\(arguments) should have thrown")
            } catch let error as ToolError {
                #expect(error.identifier == .invalidArgument)
            }
        }
    }
}
