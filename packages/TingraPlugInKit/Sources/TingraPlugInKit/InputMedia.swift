//
//  InputMedia.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The media an input produces: video, audio, both, or neither.
///
/// This is the *media* axis, and it is deliberately separate from
/// ``InputKind``, which is the *provenance* axis — what a thing is and
/// whether it captures or synthesizes. The two coincide for capture devices
/// (a camera produces video, a microphone audio) and come apart for
/// generators, where `InputKind.generator` says only that the content is
/// synthesized: bars produce video and tone produces audio, and nothing in
/// the kind distinguishes them. A media file asks the same question and
/// gets the same non-answer from the kind alone.
///
/// **This is a declaration of intent, not a guarantee.** It answers "what
/// should this input be offered for" — which pickers list it, whether it may
/// become a layer or a channel strip — not "what will certainly arrive". An
/// input that declares `.video` may still deliver no frames (a device that
/// fails to start, a network feed that never connects), so consumers keep
/// tolerating an empty stream exactly as they do without this property. It
/// changes what is *listed*, never what is *handled*.
public struct InputMedia: OptionSet, Sendable, Hashable {
    /// The raw bit set backing the option set.
    public let rawValue: Int

    /// Creates a media set from its raw bit set.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The input produces video frames on ``Input/frames()``.
    public static let video = InputMedia(rawValue: 1 << 0)

    /// The input produces audio buffers on ``Input/audio()``.
    public static let audio = InputMedia(rawValue: 1 << 1)
}
