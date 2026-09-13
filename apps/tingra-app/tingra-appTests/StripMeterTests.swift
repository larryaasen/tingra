//
//  StripMeterTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import SwiftUI
import Testing
import TingraAudio
import TingraEventBus
import TingraPlugInKit

@testable import TingraApp

/// The relay's peak hold: folded per block as the maximum since the last
/// reset, never decaying, reset per strip and for the master.
@Suite("MeterRelay peak hold")
@MainActor
struct MeterRelayPeakHoldTests {
    /// A strip id the tests meter.
    private let mic = InputID(rawValue: "mic")

    /// A block with one strip reading and a master reading.
    private func block(strip peak: Float, left: Float = 0, right: Float = 0) -> MeterBlock {
        MeterBlock(
            time: .zero,
            strips: [mic: MeterReading(peak: peak, rms: peak / 2)],
            master: StereoMeterReading(
                left: MeterReading(peak: left, rms: left / 2), right: MeterReading(peak: right, rms: right / 2))
        )
    }

    @Test("nothing is held before the first block")
    func nothingHeldBeforeFirstBlock() {
        let relay = MeterRelay()
        #expect(relay.heldPeaks.isEmpty)
        #expect(relay.heldMasterPeak == 0)
    }

    @Test("a block's peak is held, and a quieter block does not lower it")
    func quieterBlockKeepsTheHold() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0.8))
        relay.fold(block(strip: 0.2))
        #expect(relay.heldPeaks[mic] == 0.8)
        // The latest reading still follows every block.
        #expect(relay.latest[mic]?.peak == 0.2)
    }

    @Test("a louder block raises the hold")
    func louderBlockRaisesTheHold() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0.2))
        relay.fold(block(strip: 0.9))
        #expect(relay.heldPeaks[mic] == 0.9)
    }

    @Test("the master holds the louder channel")
    func masterHoldsTheLouderChannel() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0, left: 0.3, right: 0.7))
        relay.fold(block(strip: 0, left: 0.5, right: 0.1))
        #expect(relay.heldMasterPeak == 0.7)
    }

    @Test("resetting a strip's hold clears it and leaves the others")
    func resetIsPerStrip() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0.8, left: 0.6, right: 0.6))
        relay.resetPeak(forInput: mic)
        #expect(relay.heldPeaks[mic] == nil)
        #expect(relay.heldMasterPeak == 0.6)
        relay.resetMasterPeak()
        #expect(relay.heldMasterPeak == 0)
        #expect(relay.latest[mic]?.peak == 0.8)
    }

    @Test("a reset hold starts over from the next block")
    func resetHoldStartsOver() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0.8))
        relay.resetPeak(forInput: mic)
        relay.fold(block(strip: 0.3))
        #expect(relay.heldPeaks[mic] == 0.3)
    }
}

/// The peak readout's figure and over threshold.
@Suite("PeakReadout")
@MainActor
struct PeakReadoutTests {
    @Test("no hold reads as nothing")
    func noHoldReadsNothing() {
        #expect(PeakReadout.text(forHeldPeak: nil) == nil)
        #expect(PeakReadout.text(forHeldPeak: 0) == nil)
    }

    @Test("a held peak reads in dBFS to one decimal")
    func heldPeakReadsInDecibels() {
        #expect(PeakReadout.text(forHeldPeak: 0.5) == (-6.0).formatted(.number.precision(.fractionLength(1))))
        #expect(PeakReadout.text(forHeldPeak: 1) == (0.0).formatted(.number.precision(.fractionLength(1))))
    }

    @Test("full scale and above is an over; below it is not")
    func overThreshold() {
        #expect(PeakReadout.isOver(1))
        #expect(PeakReadout.isOver(1.5))
        #expect(!PeakReadout.isOver(0.999))
        #expect(!PeakReadout.isOver(nil))
    }

    @Test("the reset tap names the strip, or the master")
    func tapID() {
        #expect(PeakSubject.strip(InputID(rawValue: "mic")).tapID == "mic")
        #expect(PeakSubject.master.tapID == "master")
    }
}

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
