//
//  MeterLevels.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// One meter's level over a window of the mix: what a `tingra/meters`
/// notification carries per channel strip and per master channel
/// (PLUGINS.md, Decision 18).
///
/// Both figures are **linear sample magnitudes** — `0` is silence, `1` is
/// full scale (0 dBFS), and a peak above `1` is an over — the engine's raw
/// truth, because silence has no finite decibel figure for JSON to carry.
/// ``decibels(_:)`` converts one for display. Ballistics (attack, decay,
/// hold) are the reader's: the app applies its own at draw time and sends
/// none.
public struct MeterLevel: Sendable, Equatable {
    /// The largest absolute sample value in the window — the headroom
    /// signal. No hot sample between two notifications is lost: the app
    /// folds every mix block's peak into the window it sends.
    public let peak: Double

    /// The window's root-mean-square — the loudness signal.
    public let rms: Double

    /// Silence: what an absent or silent signal meters as.
    public static let floor = MeterLevel(peak: 0, rms: 0)

    /// Creates a level.
    ///
    /// - Parameters:
    ///   - peak: The largest absolute sample value in the window.
    ///   - rms: The window's RMS.
    public init(peak: Double, rms: Double) {
        self.peak = peak
        self.rms = rms
    }

    /// A linear sample magnitude in dBFS: `0` at full scale, negative
    /// below it, and `-.infinity` for silence.
    ///
    /// - Parameter magnitude: A ``peak`` or an ``rms``.
    /// - Returns: The level in dBFS.
    public static func decibels(_ magnitude: Double) -> Double {
        magnitude > 0 ? 20 * log10(magnitude) : -.infinity
    }

    /// The level as the notification carries it: `{"peak": …, "rms": …}`.
    public var jsonValue: JSONValue {
        .object([
            AppTierMethod.MetersParam.peak: .double(peak),
            AppTierMethod.MetersParam.rms: .double(rms),
        ])
    }

    /// Reads a level from the notification's JSON, or nil when either
    /// figure is missing or not a number.
    ///
    /// - Parameter jsonValue: A `{"peak": …, "rms": …}` object.
    public init?(jsonValue: JSONValue?) {
        guard let peak = jsonValue?[AppTierMethod.MetersParam.peak]?.doubleValue,
            let rms = jsonValue?[AppTierMethod.MetersParam.rms]?.doubleValue
        else { return nil }
        self.init(peak: peak, rms: rms)
    }
}

/// One `tingra/meters` notification: every channel strip's level and the
/// master's over the window since the last one — at most ten a second,
/// whatever the mix tick's rate (PLUGINS.md, Decision 18).
///
/// A strip's level is **pre-fader**, what its meter in the app shows; the
/// master's is the program mix **post-fader**, one level per program
/// channel (GLOSSARY.md, "Meter", "Master").
public struct MeterLevels: Sendable, Equatable {
    /// The window's last mix tick on the master clock, in seconds.
    public let time: Double

    /// Each live channel strip's pre-fader level, keyed by input id — the
    /// ids `tingra://inputs` lists.
    public let strips: [InputID: MeterLevel]

    /// The program mix's post-fader level on the left program channel.
    public let masterLeft: MeterLevel

    /// The program mix's post-fader level on the right program channel.
    public let masterRight: MeterLevel

    /// Creates a window's levels.
    ///
    /// - Parameters:
    ///   - time: The window's last mix tick, in seconds.
    ///   - strips: Each strip's level, keyed by input id.
    ///   - masterLeft: The master's left channel.
    ///   - masterRight: The master's right channel.
    public init(time: Double, strips: [InputID: MeterLevel], masterLeft: MeterLevel, masterRight: MeterLevel) {
        self.time = time
        self.strips = strips
        self.masterLeft = masterLeft
        self.masterRight = masterRight
    }

    /// The levels as the notification's params:
    /// `{"time": …, "strips": {"<inputID>": {…}}, "master": {"left": {…}, "right": {…}}}`.
    public var jsonValue: JSONValue {
        var stripValues: [String: JSONValue] = [:]
        for (id, level) in strips {
            stripValues[id.rawValue] = level.jsonValue
        }
        return .object([
            AppTierMethod.MetersParam.time: .double(time),
            AppTierMethod.MetersParam.strips: .object(stripValues),
            AppTierMethod.MetersParam.master: .object([
                AppTierMethod.MetersParam.left: masterLeft.jsonValue,
                AppTierMethod.MetersParam.right: masterRight.jsonValue,
            ]),
        ])
    }

    /// Reads a notification's params, or nil when the time, the strips, or
    /// either master channel is missing or malformed. A strip whose level
    /// does not read is a malformed notification, not a strip left out.
    ///
    /// - Parameter jsonValue: The `tingra/meters` params.
    public init?(jsonValue: JSONValue?) {
        guard let time = jsonValue?[AppTierMethod.MetersParam.time]?.doubleValue,
            let stripValues = jsonValue?[AppTierMethod.MetersParam.strips]?.objectValue,
            let master = jsonValue?[AppTierMethod.MetersParam.master],
            let left = MeterLevel(jsonValue: master[AppTierMethod.MetersParam.left]),
            let right = MeterLevel(jsonValue: master[AppTierMethod.MetersParam.right])
        else { return nil }
        var strips: [InputID: MeterLevel] = [:]
        for (id, value) in stripValues {
            guard let level = MeterLevel(jsonValue: value) else { return nil }
            strips[InputID(rawValue: id)] = level
        }
        self.init(time: time, strips: strips, masterLeft: left, masterRight: right)
    }
}
