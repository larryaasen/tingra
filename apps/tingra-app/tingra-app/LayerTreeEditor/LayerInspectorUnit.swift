//
//  LayerInspectorUnit.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import SwiftUI
import TingraComposition

/// The unit the inspector's position and size fields read and write —
/// program pixels by default, or percent — over the layer's normalized
/// frame (ARCHITECTURE.md, "The layer inspector"). Pure, so the round trip
/// is unit-tested: a pixel value is rounded to a whole pixel on the way out
/// and lands on the same pixel on the way back.
enum LayerInspectorUnit: String, CaseIterable, Sendable {
    case pixels
    case percent

    /// The unit's localized name, for the toggle.
    var title: Text {
        switch self {
        case .pixels: Text("Pixels", comment: "Layer inspector unit: program pixels")
        case .percent: Text("Percent", comment: "Layer inspector unit: percent of the program")
        }
    }

    /// How many fraction digits the fields show: whole pixels, tenths of a
    /// percent.
    var fractionDigits: Int {
        switch self {
        case .pixels: 0
        case .percent: 1
        }
    }

    /// The field's stepper increment, in the unit.
    var step: Double {
        1
    }

    /// The program's extent along an axis, in the unit — what `1.0`
    /// normalized reads as.
    ///
    /// - Parameters:
    ///   - axis: Horizontal for x and width, vertical for y and height.
    ///   - format: The program format.
    /// - Returns: The program's width or height in pixels, or 100.
    func extent(along axis: Axis, in format: ProgramFormat) -> Double {
        switch self {
        case .pixels: Double(axis == .horizontal ? format.width : format.height)
        case .percent: 100
        }
    }

    /// A normalized value as the field shows it.
    ///
    /// - Parameters:
    ///   - normalized: The frame component, as a fraction of the program.
    ///   - axis: The component's axis.
    ///   - format: The program format.
    /// - Returns: The value in the unit, whole pixels rounded.
    func value(_ normalized: CGFloat, along axis: Axis, in format: ProgramFormat) -> Double {
        let scaled = Double(normalized) * extent(along: axis, in: format)
        return self == .pixels ? scaled.rounded() : scaled
    }

    /// A typed value back as a fraction of the program.
    ///
    /// - Parameters:
    ///   - value: The value in the unit.
    ///   - axis: The component's axis.
    ///   - format: The program format.
    /// - Returns: The normalized component.
    func normalized(_ value: Double, along axis: Axis, in format: ProgramFormat) -> CGFloat {
        CGFloat(value / extent(along: axis, in: format))
    }
}
