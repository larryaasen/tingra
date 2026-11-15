//
//  MonitorGuideGeometryTests.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Testing

@testable import TingraMonitorPlugIns

@Suite("Monitor guide geometry")
struct MonitorGuideGeometryTests {
    /// A 16:9 picture letterboxed 60 pixels up a drawable.
    private let picture = CGRect(x: 0, y: 60, width: 1600, height: 900)

    @Test("a safe area keeps the given share of each dimension, centered")
    func safeArea() {
        let title = MonitorGuideGeometry.safeArea(in: picture, fraction: 0.9)
        #expect(title == CGRect(x: 80, y: 105, width: 1440, height: 810))
        #expect(title.midX == picture.midX)
        #expect(title.midY == picture.midY)
    }

    @Test("a safe area's share is clamped to the whole picture and to nothing")
    func safeAreaClamps() {
        #expect(MonitorGuideGeometry.safeArea(in: picture, fraction: 1.5) == picture)
        #expect(MonitorGuideGeometry.safeArea(in: picture, fraction: -1).isEmpty)
    }

    @Test("a 9:16 crop of a 16:9 picture is full height and centered")
    func verticalCrop() {
        let crop = MonitorGuideGeometry.cropArea(in: picture, aspect: 9.0 / 16.0)
        #expect(crop.height == 900)
        #expect(crop.width == 506)
        #expect(abs(crop.midX - picture.midX) <= 0.5)
        #expect(crop.minY == picture.minY)
    }

    @Test("a 16:9 crop of a portrait picture is full width")
    func landscapeCropOfPortrait() {
        let portrait = CGRect(x: 0, y: 0, width: 540, height: 960)
        let crop = MonitorGuideGeometry.cropArea(in: portrait, aspect: 16.0 / 9.0)
        #expect(crop.width == 540)
        #expect(crop.height == 304)
        #expect(abs(crop.midY - portrait.midY) <= 0.5)
    }

    @Test("a crop with no usable aspect, or of an empty picture, keeps the picture")
    func cropEdgeCases() {
        #expect(MonitorGuideGeometry.cropArea(in: picture, aspect: 0) == picture)
        #expect(MonitorGuideGeometry.cropArea(in: picture, aspect: .infinity) == picture)
        #expect(MonitorGuideGeometry.cropArea(in: .zero, aspect: 1) == .zero)
    }

    @Test("1920 by 1080 matches 16:9 and does not match 4:3")
    func aspectsMatch() {
        #expect(MonitorGuideGeometry.aspectsMatch(1920.0 / 1080.0, 16.0 / 9.0))
        #expect(MonitorGuideGeometry.aspectsMatch(1080.0 / 1920.0, 9.0 / 16.0))
        #expect(!MonitorGuideGeometry.aspectsMatch(1920.0 / 1080.0, 4.0 / 3.0))
        #expect(!MonitorGuideGeometry.aspectsMatch(0, 1))
    }

    @Test("an outline is four strips inside the rectangle, none overlapping")
    func outline() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let strips = MonitorGuideGeometry.outline(of: rect, lineWidth: 2)
        #expect(strips.count == 4)
        for strip in strips {
            #expect(rect.contains(strip))
        }
        #expect(strips[0] == CGRect(x: 10, y: 20, width: 100, height: 2))
        #expect(strips[1] == CGRect(x: 10, y: 68, width: 100, height: 2))
        #expect(strips[2] == CGRect(x: 10, y: 22, width: 2, height: 46))
        #expect(strips[3] == CGRect(x: 108, y: 22, width: 2, height: 46))
        let area = strips.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        #expect(area == CGFloat(100 * 50 - 96 * 46))
    }

    @Test("an empty rectangle or a non-positive width has no outline")
    func outlineEdgeCases() {
        #expect(MonitorGuideGeometry.outline(of: .zero, lineWidth: 2).isEmpty)
        #expect(MonitorGuideGeometry.outline(of: picture, lineWidth: 0).isEmpty)
    }

    @Test("the center cross is two arms crossing at the picture's center")
    func centerCross() {
        let arms = MonitorGuideGeometry.centerCross(in: picture, armFraction: 0.1, lineWidth: 2)
        #expect(arms.count == 2)
        #expect(arms[0] == CGRect(x: 755, y: 509, width: 90, height: 2))
        #expect(arms[1] == CGRect(x: 799, y: 465, width: 2, height: 90))
        #expect(MonitorGuideGeometry.centerCross(in: .zero, armFraction: 0.1, lineWidth: 2).isEmpty)
    }

    @Test("the horizontal mirror swaps the sides of its line and keeps the line")
    func horizontalMirror() {
        let mirror = MonitorGuideGeometry.horizontalMirror(about: 800)
        #expect(CGPoint(x: 800, y: 10).applying(mirror) == CGPoint(x: 800, y: 10))
        #expect(CGPoint(x: 0, y: 60).applying(mirror) == CGPoint(x: 1600, y: 60))
        #expect(picture.applying(mirror) == picture)
    }

    @Test("the center lines cross at the picture's center and run edge to edge")
    func centerLines() {
        let lines = MonitorGuideGeometry.centerLines(in: picture, lineWidth: 2)
        #expect(lines.count == 2)
        #expect(lines[0] == CGRect(x: 0, y: 509, width: 1600, height: 2))
        #expect(lines[1] == CGRect(x: 799, y: 60, width: 2, height: 900))
        #expect(MonitorGuideGeometry.centerLines(in: .zero, lineWidth: 2).isEmpty)
        #expect(MonitorGuideGeometry.centerLines(in: picture, lineWidth: 0).isEmpty)
    }

    @Test("the thirds are two vertical and two horizontal lines at a third and two thirds")
    func thirds() {
        let lines = MonitorGuideGeometry.thirds(in: picture, lineWidth: 2)
        #expect(lines.count == 4)
        #expect(lines[0].midX.rounded() == 533)
        #expect(lines[1].midX.rounded() == 1067)
        #expect(lines[2].midY == 360)
        #expect(lines[3].midY == 660)
        #expect(lines[0].height == picture.height)
        #expect(lines[2].width == picture.width)
        #expect(MonitorGuideGeometry.thirds(in: picture, lineWidth: 0).isEmpty)
    }

    @Test("the bands round a centered crop are its two sides, and none round the whole picture")
    func bands() {
        let crop = CGRect(x: 547, y: 60, width: 506, height: 900)
        let bands = MonitorGuideGeometry.bands(around: crop, in: picture)
        #expect(
            bands == [CGRect(x: 0, y: 60, width: 547, height: 900), CGRect(x: 1053, y: 60, width: 547, height: 900)])
        #expect(MonitorGuideGeometry.bands(around: picture, in: picture).isEmpty)
        let apart = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        #expect(MonitorGuideGeometry.bands(around: apart, in: picture) == [picture])
    }

    @Test("snapping moves each edge to the nearest whole pixel")
    func snapped() {
        let rect = CGRect(x: 10.4, y: 10.6, width: 20.2, height: 4.8)
        #expect(MonitorGuideGeometry.snapped(rect) == CGRect(x: 10, y: 11, width: 21, height: 4))
    }
}
