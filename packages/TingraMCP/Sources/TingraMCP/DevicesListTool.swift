//
//  DevicesListTool.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraHost
import TingraPlugInKit

/// The `devices_list` tool: input discovery for agents, mirroring
/// `tingra-cli devices --json` (CLI.md) — the same stable identifiers and the
/// same `cameras`/`microphones` document shape, so a script and an agent see
/// one contract.
struct DevicesListTool: Tool {
    /// The input registry the listing is built from.
    private let inputs: InputRegistry

    /// Creates the tool over the host's input registry.
    init(inputs: InputRegistry) {
        self.inputs = inputs
    }

    let name = "devices_list"
    let title = "List Devices"
    let description =
        "List the cameras and microphones available for capture, with the stable identifiers used "
        + "as stream_start selectors. Mirrors `tingra-cli devices --json`."

    /// One optional argument, `type`, narrowing the listing to a kind.
    let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "type": .object([
                "type": .string("string"),
                "enum": .array([.string("camera"), .string("mic"), .string("all")]),
                "description": .string("Limit the listing to one input kind. Defaults to all."),
            ])
        ]),
    ])

    func call(_ arguments: JSONValue) async throws -> JSONValue {
        let type = arguments["type"]?.stringValue ?? "all"
        guard ["camera", "mic", "all"].contains(type) else {
            throw ToolError(
                identifier: .invalidArgument,
                message: "The 'type' argument must be one of 'camera', 'mic', or 'all'."
            )
        }
        let all = await inputs.allInputs
        var result: [String: JSONValue] = [:]
        if type != "mic" {
            result["cameras"] = section(all, kind: .camera)
        }
        if type != "camera" {
            result["microphones"] = section(all, kind: .microphone)
        }
        return .object(result)
    }

    /// The sorted, indexed section for one input kind — the same order and
    /// shape `devices --json` prints (sorted by name then identifier, with a
    /// presentation index). Generators are never listed as devices.
    private func section(_ inputs: [any Input], kind: InputKind) -> JSONValue {
        let devices =
            inputs
            .filter { $0.kind == kind }
            .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
            .enumerated()
            .map { offset, input in
                JSONValue.object([
                    "index": .int(offset),
                    "name": .string(input.name),
                    "id": .string(input.id.rawValue),
                ])
            }
        return .array(devices)
    }
}
