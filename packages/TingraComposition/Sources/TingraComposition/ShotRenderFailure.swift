//
//  ShotRenderFailure.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-09-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo

/// Why a ``ShotRenderer`` could not produce a frame for a tick.
///
/// A thrown failure never reaches a consumer: the compositor catches it,
/// skips that bus's tick — a renderer problem must never take down the
/// pipeline (ARCHITECTURE.md) — and reports the *episode* on the event bus
/// as `program.stalled`/`program.resumed` or `preview.stalled`/
/// `preview.resumed` (EVENTS.md, "Reporting a repeating failure"). Before
/// this type the renderer returned nil and the tick was dropped with
/// nothing on the bus, so a program starved of `IOSurface` memory froze
/// with no explanation.
public enum ShotRenderFailure: Error, Equatable, Sendable {
    /// The output buffer pool could not be created for the program size, so
    /// no frame can be rendered. Carries the `CVPixelBufferPoolCreate`
    /// status.
    case pixelBufferPoolUnavailable(CVReturn)

    /// The pool could not vend an output buffer for this tick — the
    /// exhaustion case. Carries the `CVPixelBufferPoolCreatePixelBuffer`
    /// status.
    case pixelBufferUnavailable(CVReturn)

    /// Core Image could not start or complete the render — most notably
    /// when it cannot allocate an intermediate `IOSurface` under memory
    /// pressure, the condition that used to abort the process. Carries the
    /// Core Image error's code.
    case renderIncomplete(code: Int)

    /// A short stable token identifying the failed step, used verbatim as
    /// the `reason` param of a stalled/resumed event. Stable because an
    /// operator (or a test) keys off it; the human explanation lives in the
    /// case documentation above.
    public var reason: String {
        switch self {
        case .pixelBufferPoolUnavailable: "pixelBufferPool"
        case .pixelBufferUnavailable: "pixelBuffer"
        case .renderIncomplete: "render"
        }
    }

    /// The framework status or error code behind the failure, reported as
    /// the `status` param of a stalled event.
    public var status: Int {
        switch self {
        case .pixelBufferPoolUnavailable(let status), .pixelBufferUnavailable(let status): Int(status)
        case .renderIncomplete(let code): code
        }
    }
}
