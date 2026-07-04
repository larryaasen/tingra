//
//  DeviceList.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// One input in `devices` output: a camera or a microphone.
///
/// The JSON keys are a stable scripting contract (CLI.md; the `devices_list`
/// MCP tool reuses the same shape) — camelCase, mapped explicitly, never
/// renamed.
struct Device: Codable, Equatable {
    /// The position in the listing (0-based), usable as an index selector
    /// (`--camera 1`).
    let index: Int

    /// The user-facing device name, usable as a unique-substring selector
    /// (`--camera BRIO`).
    let name: String

    /// The stable identifier (see `InputID`), the exact selector form.
    let id: String

    /// The stable JSON keys.
    private enum CodingKeys: String, CodingKey {
        case index
        case name
        case id
    }
}

/// The `devices --json` document: the discovered inputs grouped by kind.
///
/// A section is absent when `--type` excludes it, and an empty array when
/// it was requested but nothing is connected — scripts can rely on the
/// distinction.
struct DeviceList: Codable, Equatable {
    /// The discovered cameras; absent under `--type mic`.
    let cameras: [Device]?

    /// The discovered microphones; absent under `--type camera`.
    let microphones: [Device]?

    /// The stable JSON keys.
    private enum CodingKeys: String, CodingKey {
        case cameras
        case microphones
    }

    /// Creates a listing from already-built sections (tests and decoding).
    init(cameras: [Device]?, microphones: [Device]?) {
        self.cameras = cameras
        self.microphones = microphones
    }
}

extension DeviceList {
    /// Builds the listing from the registered inputs: filters each section
    /// by kind, sorts by name (then identifier, for devices sharing a
    /// name), and assigns the presentation indexes.
    init(inputs: [any Input], type: DeviceType) {
        /// The sorted, indexed section for one input kind.
        func section(_ kind: InputKind) -> [Device] {
            inputs
                .filter { $0.kind == kind }
                .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
                .enumerated()
                .map { Device(index: $0.offset, name: $0.element.name, id: $0.element.id.rawValue) }
        }
        self.init(
            cameras: type == .mic ? nil : section(.camera),
            microphones: type == .camera ? nil : section(.microphone)
        )
    }

    /// The human readable table, in the CLI.md format: one section per
    /// requested kind, names column-aligned, identifiers in parentheses.
    var table: String {
        var sections: [String] = []
        if let cameras {
            sections.append(Self.section(titled: "CAMERAS", devices: cameras))
        }
        if let microphones {
            sections.append(Self.section(titled: "MICROPHONES", devices: microphones))
        }
        return sections.joined(separator: "\n")
    }

    /// One table section: the title line, then an indented row per device,
    /// or `(none)` when nothing of that kind is connected.
    private static func section(titled title: String, devices: [Device]) -> String {
        guard !devices.isEmpty else {
            return "\(title)\n  (none)"
        }
        let nameWidth = devices.map(\.name.count).max() ?? 0
        let rows = devices.map { device in
            let padding = String(repeating: " ", count: nameWidth - device.name.count + 2)
            return "  \(device.index)  \(device.name)\(padding)(id: \(device.id))"
        }
        return ([title] + rows).joined(separator: "\n")
    }
}
