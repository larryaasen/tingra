//
//  StripMeterTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import SwiftUI
import Testing
import TingraAudio

@testable import TingraApp

/// The meter ballistics under explicit timestamps: attack is instant, decay
/// follows real elapsed time at 20 dB per second on the −60…0 dBFS scale.
@Suite("MeterBallistics")
@MainActor
struct StripMeterTests {
    /// A fixed reference instant the tests advance from.
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    @Test("attack is instant: a full-scale reading fills the meter on its first draw")
    func instantAttackFillsTheMeter() {
        let ballistics = MeterBallistics()
        let smoothed = ballistics.smoothed(MeterReading(peak: 1, rms: 1), at: start)
        #expect(smoothed.rms == 1)
        #expect(smoothed.peak == 1)
    }

    @Test("the display decays at 20 dB per second once the signal drops")
    func decayFollowsElapsedTime() {
        let ballistics = MeterBallistics()
        _ = ballistics.smoothed(MeterReading(peak: 1, rms: 1), at: start)
        let smoothed = ballistics.smoothed(.floor, at: start.addingTimeInterval(1))
        // One second after full scale: 20 dB down on a 60 dB scale.
        #expect(abs(smoothed.rms - 2.0 / 3.0) < 0.0001)
        #expect(abs(smoothed.peak - 2.0 / 3.0) < 0.0001)
    }

    @Test("a louder reading overrides the decay immediately")
    func louderReadingOverridesDecay() {
        let ballistics = MeterBallistics()
        _ = ballistics.smoothed(MeterReading(peak: 0.1, rms: 0.1), at: start)
        let smoothed = ballistics.smoothed(MeterReading(peak: 1, rms: 1), at: start.addingTimeInterval(0.5))
        #expect(smoothed.rms == 1)
        #expect(smoothed.peak == 1)
    }

    @Test("silence rests at the floor")
    func silenceRestsAtTheFloor() {
        let ballistics = MeterBallistics()
        let smoothed = ballistics.smoothed(.floor, at: start)
        #expect(smoothed.rms == 0)
        #expect(smoothed.peak == 0)
    }

    @Test("a long decay bottoms out at the floor, never below")
    func decayBottomsOutAtTheFloor() {
        let ballistics = MeterBallistics()
        _ = ballistics.smoothed(MeterReading(peak: 1, rms: 1), at: start)
        // Four seconds decays 80 dB — past the 60 dB scale — and clamps.
        let smoothed = ballistics.smoothed(.floor, at: start.addingTimeInterval(4))
        #expect(smoothed.rms == 0)
        #expect(smoothed.peak == 0)
    }
}

/// The meter capsule's geometry on either axis: the bar fills from the floor
/// end toward full scale — rightward lying down, upward standing — the peak
/// marker sits at the peak and stays inside the capsule at full scale, and
/// the zone gradient runs floor to full scale along the same axis.
@Suite("MeterCapsule geometry")
@MainActor
struct MeterCapsuleGeometryTests {
    /// A lying capsule's size.
    private let horizontal = CGSize(width: 72, height: 6)

    /// A standing capsule's size.
    private let vertical = CGSize(width: 5, height: 110)

    @Test("a horizontal bar fills from the leading edge rightward")
    func horizontalBarFillsRightward() {
        let rect = MeterCapsule.barRect(fraction: 0.5, in: horizontal, axis: .horizontal)
        #expect(rect == CGRect(x: 0, y: 0, width: 36, height: 6))
    }

    @Test("a vertical bar fills from the bottom upward")
    func verticalBarFillsUpward() {
        let rect = MeterCapsule.barRect(fraction: 0.5, in: vertical, axis: .vertical)
        #expect(rect == CGRect(x: 0, y: 55, width: 5, height: 55))
    }

    @Test("a full-scale vertical bar covers the whole capsule")
    func fullScaleVerticalBarCoversTheCapsule() {
        let rect = MeterCapsule.barRect(fraction: 1, in: vertical, axis: .vertical)
        #expect(rect == CGRect(x: 0, y: 0, width: 5, height: 110))
    }

    @Test("a horizontal peak marker is a one-point line at the peak")
    func horizontalPeakMarker() {
        let rect = MeterCapsule.peakRect(fraction: 0.5, in: horizontal, axis: .horizontal)
        #expect(rect == CGRect(x: 35.5, y: 0, width: 1, height: 6))
    }

    @Test("a vertical peak marker is a one-point line at the peak, measured from the bottom")
    func verticalPeakMarker() {
        let rect = MeterCapsule.peakRect(fraction: 0.5, in: vertical, axis: .vertical)
        #expect(rect == CGRect(x: 0, y: 54.5, width: 5, height: 1))
    }

    @Test("a full-scale peak marker stays inside the capsule on either axis")
    func fullScalePeakStaysInside() {
        let lying = MeterCapsule.peakRect(fraction: 1, in: horizontal, axis: .horizontal)
        #expect(lying.maxX <= horizontal.width)
        #expect(lying.minX >= 0)
        let standing = MeterCapsule.peakRect(fraction: 1, in: vertical, axis: .vertical)
        #expect(standing.minY >= 0)
        #expect(standing.maxY <= vertical.height)
    }

    @Test("the zone gradient runs floor to full scale along the fill axis")
    func zoneLineFollowsTheFillAxis() {
        let lying = MeterCapsule.zoneLine(in: horizontal, axis: .horizontal)
        #expect(lying.start == .zero)
        #expect(lying.end == CGPoint(x: 72, y: 0))
        let standing = MeterCapsule.zoneLine(in: vertical, axis: .vertical)
        #expect(standing.start == CGPoint(x: 0, y: 110))
        #expect(standing.end == .zero)
    }
}
