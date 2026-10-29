//
//  ParameterValueFormat.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

extension Parameter {
    /// A value with the parameter's unit, e.g. "96.3 ms", "5,100 K", "2°",
    /// shown to the precision of the parameter's step: one decimal for an
    /// exposure time that moves in tenths of a millisecond, whole numbers
    /// for a brightness that moves in ones. Without a step, a range narrow
    /// enough that tenths matter shows one decimal and a wide one whole
    /// numbers. Shared by every slider.
    ///
    /// - Parameter value: The value to show.
    /// - Returns: The formatted value.
    func formattedValue(_ value: Double) -> String {
        // A zero reached from below is still zero; never show "-0".
        let shown = value == 0 ? 0 : value
        let digits: Int
        if let step {
            digits = Self.fractionDigits(of: step)
        } else {
            digits = range.upperBound - range.lowerBound < 50 ? 1 : 0
        }
        let number = shown.formatted(.number.precision(.fractionLength(digits)))
        guard let unit else { return number }
        return unit == "°" ? "\(number)°" : "\(number) \(unit)"
    }

    /// How many decimals a step needs: `0` for `1` or `10`, `1` for `0.1`,
    /// `2` for `0.25`; at most four.
    ///
    /// - Parameter step: The parameter's step.
    /// - Returns: The number of fraction digits.
    private static func fractionDigits(of step: Double) -> Int {
        for digits in 0..<4 {
            let scaled = step * pow(10, Double(digits))
            if abs(scaled - scaled.rounded()) < 1e-9 { return digits }
        }
        return 4
    }
}
