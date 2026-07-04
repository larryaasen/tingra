//
//  Input.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A stable identifier for an input, as surfaced by input discovery
/// (`tingra-cli devices --json`, the `devices_list` MCP tool).
///
/// Identifiers are a stable scripting contract: the same physical device
/// yields the same identifier across launches wherever the platform allows.
public struct InputID: RawRepresentable, Hashable, Sendable, Codable {
    /// The identifier string, e.g. a device unique ID or a generator name.
    public let rawValue: String

    /// Creates an identifier from its string form.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Anything that produces video or audio frames for the pipeline: a display,
/// a window, an application, a camera, a microphone, a media file, a network
/// feed, or a generator (see GLOSSARY.md).
///
/// The compositor and everything downstream consume this protocol and never
/// import a capture framework directly — only the plug-in behind the
/// protocol does. Inputs normalize framework timestamps onto the master
/// clock and apply the per input sync offset (see CLOCK.md); frames are
/// delivered already tagged and in the working pixel format (see
/// ARCHITECTURE.md, "Color and pixel format conventions").
public protocol Input: Sendable {
    /// The input's stable identifier.
    var id: InputID { get }

    /// Begins producing frames.
    ///
    /// Throws a descriptive error if the input cannot start — authorization
    /// denied, device unavailable. Device disconnection after a successful
    /// start is a normal event, never an error.
    func start() async throws

    /// The stream of captured frames, GPU-resident, timestamped on the
    /// master clock. Finishes when the input stops.
    func frames() -> AsyncStream<CapturedFrame>

    /// Stops producing frames and releases the underlying device or
    /// resources. Safe to call more than once.
    func stop() async
}
