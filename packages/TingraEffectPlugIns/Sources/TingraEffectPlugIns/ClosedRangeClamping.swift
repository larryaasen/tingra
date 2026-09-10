//
//  ClosedRangeClamping.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

extension ClosedRange where Bound == Double {
    /// `value` pulled into the range — how every effect keeps a payload
    /// inside its declared parameter range (the Frame's sizes, the Crop's
    /// insets), shared so the rule lives once.
    func clamping(_ value: Double) -> Double {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
