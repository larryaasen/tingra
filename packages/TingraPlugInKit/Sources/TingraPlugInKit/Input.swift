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

    /// A short user-facing name for discovery listings and pickers, e.g.
    /// "FaceTime HD Camera". Also a selector form: `--camera BRIO` matches
    /// by unique name substring (see CLI.md, "Input selection").
    var name: String { get }

    /// The kind of input, driving grouping in discovery output and selector
    /// resolution.
    var kind: InputKind { get }

    /// Begins producing frames.
    ///
    /// Throws a descriptive error if the input cannot start — authorization
    /// denied, device unavailable. Device disconnection after a successful
    /// start is a normal event, never an error.
    func start() async throws

    /// The stream of captured video frames, GPU-resident, timestamped on
    /// the master clock. Finishes when the input stops. Audio-only inputs
    /// keep the default implementation, an already-finished stream.
    func frames() -> AsyncStream<CapturedFrame>

    /// The stream of captured audio buffers, timestamped on the master
    /// clock (PTS from `AVAudioTime` host time, see CLOCK.md). Finishes
    /// when the input stops. Video-only inputs keep the default
    /// implementation, an already-finished stream.
    func audio() -> AsyncStream<CapturedAudio>

    /// Stops producing frames and releases the underlying device or
    /// resources. Safe to call more than once.
    func stop() async
}

extension Input {
    /// By default an input produces no video: an already-finished stream.
    /// Video inputs (cameras, displays, video generators) override this.
    public func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream { $0.finish() }
    }

    /// By default an input produces no audio: an already-finished stream.
    /// Audio inputs (microphones, audio generators) override this.
    public func audio() -> AsyncStream<CapturedAudio> {
        AsyncStream { $0.finish() }
    }
}
