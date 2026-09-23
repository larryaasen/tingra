//
//  BusFrame.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import IOSurface
import TingraPlugInKit

/// A video bus whose frames a plug-in can follow
/// (``PlugInConnection/frames(_:)``): the two the app's own monitors show
/// (GLOSSARY.md, "Program", "Preview").
public enum FrameBus: String, Sendable, Codable, CaseIterable {
    /// What viewers see: the composited program, after fade to black.
    case program

    /// The staging bus: the shot staged for the next take. Empty while
    /// nothing is staged.
    case preview
}

/// One frame of a bus as it reaches a plug-in: the app's own `IOSurface`,
/// handed across the process boundary with no copy (PLUGINS.md, "Frames
/// across the boundary").
///
/// The surface is the app's working format — 32-bit BGRA, SDR, BT.709
/// (ARCHITECTURE.md, "Color and pixel format conventions") — at the program
/// format's size, and it is **shared memory, not a snapshot**: the app
/// recycles a frame's surface once nobody is using it, so draw it (a
/// `CALayer`'s contents, a Metal texture made from it) rather than keep it,
/// and never write to it. A plug-in that must hold one past the next frame
/// marks it in use (`incrementUseCount()`), and gives it back promptly.
public struct BusFrame: Sendable {
    /// The bus the frame is from.
    public let bus: FrameBus

    /// The frame's pixels, or nil when the bus has nothing on it — preview
    /// with no shot staged — so a monitor empties instead of holding a
    /// stale picture.
    public let surface: IOSurface?

    /// The frame's time on the app's master clock, in seconds; `0` for an
    /// empty bus.
    public let time: Double

    /// Creates a frame.
    ///
    /// - Parameters:
    ///   - bus: The bus the frame is from.
    ///   - surface: The frame's pixels, or nil for an empty bus.
    ///   - time: The frame's time on the master clock, in seconds.
    public init(bus: FrameBus, surface: IOSurface?, time: Double) {
        self.bus = bus
        self.surface = surface
        self.time = time
    }

    /// The JSON half of a `tingra/frame` notification — everything but the
    /// surface, which rides beside it: `{"bus": …, "time": …, "empty": …}`.
    public var jsonValue: JSONValue {
        .object([
            AppTierMethod.FrameParam.bus: .string(bus.rawValue),
            AppTierMethod.FrameParam.time: .double(time),
            AppTierMethod.FrameParam.empty: .bool(surface == nil),
        ])
    }

    /// Reads a `tingra/frame` notification, or nil when it names no bus
    /// this kit knows, or claims pixels it did not bring: a notification
    /// that is not marked empty and has no surface attached is malformed,
    /// never an empty bus.
    ///
    /// - Parameters:
    ///   - jsonValue: The notification's params.
    ///   - surface: The surface attached to the message, if any.
    public init?(jsonValue: JSONValue?, surface: IOSurface?) {
        guard let name = jsonValue?[AppTierMethod.FrameParam.bus]?.stringValue, let bus = FrameBus(rawValue: name)
        else { return nil }
        let isEmpty = jsonValue?[AppTierMethod.FrameParam.empty]?.boolValue ?? false
        guard isEmpty != (surface != nil) else { return nil }
        self.init(bus: bus, surface: surface, time: jsonValue?[AppTierMethod.FrameParam.time]?.doubleValue ?? 0)
    }
}
