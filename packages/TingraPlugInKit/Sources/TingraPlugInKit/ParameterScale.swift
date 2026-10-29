//
//  ParameterScale.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The pure mapping between a declared parameter's value and a slider's
/// travel, honoring the scale the parameter declares (`Parameter.Scale`):
/// equal travel covers equal spans on a linear parameter and equal ratios
/// on a logarithmic one, so a 20 Hz–20 kHz frequency puts 440 Hz near the
/// middle of the slider rather than at two percent of it. Every generic
/// parameter slider — the app's two effect chain editors and its input
/// settings, and Tingra Cameras' camera controls — drives its slider in
/// `0…1` through these two functions. Moved from the app into the kit on
/// 2026-10-27, when a second host began drawing sliders (docs/UVC.md).
///
/// A value read off the travel is snapped to the parameter's declared step
/// (`Parameter.snapped(_:)`), so a slider rests only on values the
/// parameter takes.
///
/// A logarithmic parameter whose range touches or crosses zero has no
/// ratio to map, so it falls back to linear rather than producing a NaN;
/// a range with no width maps everything to the lower bound.
public enum ParameterScale {
    /// The slider position, `0…1`, showing a value of the parameter.
    ///
    /// - Parameters:
    ///   - value: The parameter's value; a value outside the range clamps
    ///     to the nearest end of the travel.
    ///   - parameter: The parameter, whose range and scale decide the map.
    /// - Returns: The position along the slider.
    public static func position(of value: Double, for parameter: Parameter) -> Double {
        let lower = parameter.range.lowerBound
        let upper = parameter.range.upperBound
        guard upper > lower else { return 0 }
        let clamped = parameter.clamped(value)
        let position: Double
        if isLogarithmic(parameter) {
            position = log(clamped / lower) / log(upper / lower)
        } else {
            position = (clamped - lower) / (upper - lower)
        }
        return min(1, max(0, position))
    }

    /// The parameter's value at a slider position.
    ///
    /// - Parameters:
    ///   - position: The position along the slider, `0…1`; a position
    ///     outside that travel clamps to the nearest end.
    ///   - parameter: The parameter, whose range and scale decide the map.
    /// - Returns: The value, within the parameter's range and on its step.
    public static func value(at position: Double, for parameter: Parameter) -> Double {
        let lower = parameter.range.lowerBound
        let upper = parameter.range.upperBound
        guard upper > lower else { return lower }
        let travel = min(1, max(0, position))
        let value: Double
        if isLogarithmic(parameter) {
            value = lower * pow(upper / lower, travel)
        } else {
            value = lower + travel * (upper - lower)
        }
        return parameter.snapped(value)
    }

    /// Whether the parameter maps by ratio: it declares the logarithmic
    /// scale and its range is strictly positive, so the ratio exists.
    private static func isLogarithmic(_ parameter: Parameter) -> Bool {
        parameter.scale == .logarithmic && parameter.range.lowerBound > 0
    }
}
