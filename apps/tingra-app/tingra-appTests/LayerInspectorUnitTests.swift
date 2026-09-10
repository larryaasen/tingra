//
//  LayerInspectorUnitTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import Testing
import TingraComposition

@testable import TingraApp

@Suite("LayerInspectorUnit")
struct LayerInspectorUnitTests {
    private let format = ProgramFormat(width: 1920, height: 1080, frameRate: 30)

    @Test("pixels read the program's width and height, percent reads 100")
    func extents() {
        #expect(LayerInspectorUnit.pixels.extent(along: .horizontal, in: format) == 1920)
        #expect(LayerInspectorUnit.pixels.extent(along: .vertical, in: format) == 1080)
        #expect(LayerInspectorUnit.percent.extent(along: .horizontal, in: format) == 100)
        #expect(LayerInspectorUnit.percent.extent(along: .vertical, in: format) == 100)
    }

    @Test("the built-in inset reads as whole pixels and percent")
    func values() {
        let frame = ProgramLayout.cameraInsetFrame
        #expect(LayerInspectorUnit.pixels.value(frame.minX, along: .horizontal, in: format) == 1306)
        #expect(LayerInspectorUnit.pixels.value(frame.minY, along: .vertical, in: format) == 734)
        #expect(LayerInspectorUnit.pixels.value(frame.width, along: .horizontal, in: format) == 538)
        #expect(abs(LayerInspectorUnit.percent.value(frame.width, along: .horizontal, in: format) - 28) < 1e-9)
    }

    @Test("a typed pixel value lands on the same pixel when read back")
    func pixelRoundTrip() {
        for pixel in [0.0, 1.0, 480.0, 1306.0, 1919.0, 1920.0] {
            let normalized = LayerInspectorUnit.pixels.normalized(pixel, along: .horizontal, in: format)
            #expect(LayerInspectorUnit.pixels.value(normalized, along: .horizontal, in: format) == pixel)
        }
        let normalized = LayerInspectorUnit.pixels.normalized(1080, along: .vertical, in: format)
        #expect(abs(normalized - 1) < 1e-9)
    }

    @Test("a typed percent round-trips too")
    func percentRoundTrip() {
        let normalized = LayerInspectorUnit.percent.normalized(28, along: .vertical, in: format)
        #expect(abs(normalized - 0.28) < 1e-9)
        #expect(abs(LayerInspectorUnit.percent.value(normalized, along: .vertical, in: format) - 28) < 1e-9)
    }

    @Test("pixels show no fraction digits, percent shows one")
    func digits() {
        #expect(LayerInspectorUnit.pixels.fractionDigits == 0)
        #expect(LayerInspectorUnit.percent.fractionDigits == 1)
        #expect(LayerInspectorUnit.allCases.count == 2)
    }
}
