//
//  GeneratorSynthesisFailure.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import Foundation

/// Why a generator could not synthesize output for a tick.
///
/// Every case names one Core Video, Core Graphics, or Core Media call that
/// would otherwise have been discarded — the renderers used to return nil and
/// the tick was skipped with nothing on the bus, so a persistently broken
/// generator (an exhausted pool, say) produced no output and no signal, which
/// reads as a hang rather than as a reported problem.
///
/// A thrown failure never reaches a consumer: the stream coordinator catches
/// it, skips the tick as before — a generator problem must never take down the
/// pipeline (ARCHITECTURE.md) — and reports the *episode* on the event bus per
/// EVENTS.md, "Reporting a repeating failure".
///
/// Internal on purpose: it is a diagnostic detail of this package, and it
/// reaches the outside world only as the `reason` and `status` params of a
/// `generator.stalled` event, never as API.
enum GeneratorSynthesisFailure: Error, Equatable {
    /// The renderer's pixel buffer pool could not be created, so no frame can
    /// ever be drawn. Carries the `CVPixelBufferPoolCreate` status.
    case pixelBufferPoolUnavailable(CVReturn)

    /// The pool could not vend a buffer for this tick — the exhaustion case,
    /// which is transient in principle and so the one most likely to resume.
    /// Carries the `CVPixelBufferPoolCreatePixelBuffer` status.
    case pixelBufferUnavailable(CVReturn)

    /// Core Graphics would not create a drawing context over the buffer's
    /// bytes. Core Graphics reports no status code of its own.
    case drawingContextUnavailable

    /// The cached pattern image could not be built at renderer creation, so
    /// there is nothing to copy into a frame (the alignment generator only).
    case patternImageUnavailable

    /// The shared PCM format description could not be created, so no audio
    /// buffer can be produced. Carries the `CMAudioFormatDescriptionCreate`
    /// status.
    case audioFormatDescriptionUnavailable(OSStatus)

    /// The block buffer backing this tick's samples could not be allocated or
    /// filled. Carries the `CMBlockBuffer` call's status.
    case audioBlockBufferUnavailable(OSStatus)

    /// The sample buffer wrapping this tick's samples could not be created.
    /// Carries the `CMAudioSampleBufferCreateReadyWithPacketDescriptions`
    /// status.
    case audioSampleBufferUnavailable(OSStatus)

    /// A short stable token identifying the failed call, used verbatim as the
    /// `reason` param of a `generator.stalled` event. Stable because an
    /// operator (or a test) keys off it; the human explanation lives in the
    /// case documentation above, not in this string.
    var reason: String {
        switch self {
        case .pixelBufferPoolUnavailable: "pixelBufferPool"
        case .pixelBufferUnavailable: "pixelBuffer"
        case .drawingContextUnavailable: "drawingContext"
        case .patternImageUnavailable: "patternImage"
        case .audioFormatDescriptionUnavailable: "audioFormatDescription"
        case .audioBlockBufferUnavailable: "audioBlockBuffer"
        case .audioSampleBufferUnavailable: "audioSampleBuffer"
        }
    }

    /// The framework status code behind the failure, where the call returned
    /// one — nil for the failures whose API reports only a null result.
    var status: OSStatus? {
        switch self {
        case .pixelBufferPoolUnavailable(let status), .pixelBufferUnavailable(let status):
            OSStatus(status)
        case .audioFormatDescriptionUnavailable(let status),
            .audioBlockBufferUnavailable(let status),
            .audioSampleBufferUnavailable(let status):
            status
        case .drawingContextUnavailable, .patternImageUnavailable:
            nil
        }
    }
}
