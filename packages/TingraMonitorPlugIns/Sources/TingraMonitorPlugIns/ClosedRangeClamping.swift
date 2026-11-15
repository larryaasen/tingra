//
//  ClosedRangeClamping.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

extension ClosedRange where Bound == Double {
    /// The value moved into the range; a value that is not a number lands
    /// on the lower bound.
    ///
    /// - Parameter value: The value to clamp.
    /// - Returns: The clamped value.
    func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return lowerBound }
        return Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
