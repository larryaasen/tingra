//
//  MeterDisplayLinkTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import CoreMedia
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing
import TingraAudio
import TingraPlugInKit

@testable import TingraApp

/// A thread-safe count of observation change callbacks, which arrive on a
/// `@Sendable` closure — nonisolated, since that closure is.
private nonisolated final class ChangeCount: Sendable {
    /// The number of changes heard.
    private let count = Mutex(0)

    /// The changes heard so far.
    var value: Int {
        count.withLock { $0 }
    }

    /// Records one change.
    func record() {
        count.withLock { $0 += 1 }
    }
}

/// A strip id the tests meter.
private let mic = InputID(rawValue: "mic")

/// A block with one strip reading and a master reading.
private func block(strip peak: Float, rms: Float? = nil, left: Float = 0, right: Float = 0) -> MeterBlock {
    MeterBlock(
        time: .zero,
        strips: [mic: MeterReading(peak: peak, rms: rms ?? peak / 2)],
        master: StereoMeterReading(
            left: MeterReading(peak: left, rms: left / 2), right: MeterReading(peak: right, rms: right / 2))
    )
}

/// Reading the relay once a frame: the snapshot, and what each meter and
/// readout subject takes from it.
@Suite("MeterRelay snapshot and subjects")
@MainActor
struct MeterRelaySnapshotTests {
    @Test("the snapshot carries the latest readings and the holds together")
    func snapshotCarriesEverything() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0.8, left: 0.3, right: 0.6))
        relay.fold(block(strip: 0.2, left: 0.1, right: 0.2))
        let snapshot = relay.snapshot
        #expect(snapshot.latest[mic]?.peak == 0.2)
        #expect(snapshot.master.right.peak == 0.2)
        #expect(snapshot.heldPeaks[mic] == 0.8)
        #expect(snapshot.heldMasterPeak == 0.6)
    }

    @Test("a strip's held peak is its hold, or nil before it has metered")
    func stripHeldPeak() {
        let relay = MeterRelay()
        #expect(PeakSubject.strip(mic).heldPeak(in: relay.snapshot) == nil)
        relay.fold(block(strip: 0.5))
        #expect(PeakSubject.strip(mic).heldPeak(in: relay.snapshot) == 0.5)
    }

    @Test("the master's held peak is nil at silence and the louder channel's hold after")
    func masterHeldPeak() {
        let relay = MeterRelay()
        #expect(PeakSubject.master.heldPeak(in: relay.snapshot) == nil)
        relay.fold(block(strip: 0, left: 0.4, right: 0.7))
        #expect(PeakSubject.master.heldPeak(in: relay.snapshot) == 0.7)
    }

    @Test("a meter subject reads its strip, the floor for an unmetered strip, or one master side")
    func meterSubjectReadings() {
        let relay = MeterRelay()
        #expect(MeterSubject.strip(mic).reading(in: relay.snapshot) == .floor)
        relay.fold(block(strip: 0.8, left: 0.3, right: 0.6))
        let snapshot = relay.snapshot
        #expect(MeterSubject.strip(mic).reading(in: snapshot).peak == 0.8)
        #expect(MeterSubject.strip(InputID(rawValue: "absent")).reading(in: snapshot) == .floor)
        #expect(MeterSubject.masterLeft.reading(in: snapshot).peak == 0.3)
        #expect(MeterSubject.masterRight.reading(in: snapshot).peak == 0.6)
    }
}

/// A peak readout's figure: made from the hold, and published only when
/// what the readout shows changes.
@Suite("PeakFigure")
@MainActor
struct PeakFigureTests {
    /// Runs `change` and returns how many observer notifications the
    /// figure's two properties sent for it.
    private func notifications(of figure: PeakFigure, during change: () -> Void) -> Int {
        let count = ChangeCount()
        withObservationTracking {
            _ = figure.text
            _ = figure.isOver
        } onChange: {
            count.record()
        }
        change()
        return count.value
    }

    @Test("a new figure shows nothing held and no over")
    func startsEmpty() {
        let figure = PeakFigure()
        #expect(figure.text == nil)
        #expect(!figure.isOver)
    }

    @Test("a hold shows as the readout's text, and full scale as an over")
    func showsTheHold() {
        let figure = PeakFigure()
        figure.show(heldPeak: 0.5)
        #expect(figure.text == PeakReadout.text(forHeldPeak: 0.5))
        #expect(!figure.isOver)
        figure.show(heldPeak: 1)
        #expect(figure.text == PeakReadout.text(forHeldPeak: 1))
        #expect(figure.isOver)
    }

    @Test("a reset hold shows nothing again")
    func resetShowsNothing() {
        let figure = PeakFigure()
        figure.show(heldPeak: 1.2)
        figure.show(heldPeak: nil)
        #expect(figure.text == nil)
        #expect(!figure.isOver)
    }

    @Test("the same hold again notifies no observer")
    func sameHoldIsSilent() {
        let figure = PeakFigure()
        figure.show(heldPeak: 0.5)
        #expect(notifications(of: figure) { figure.show(heldPeak: 0.5) } == 0)
    }

    @Test("a hold rising within the same tenth of a decibel notifies no observer")
    func riseWithinTheFigureIsSilent() {
        let figure = PeakFigure()
        figure.show(heldPeak: 0.5)
        #expect(notifications(of: figure) { figure.show(heldPeak: 0.500_01) } == 0)
        #expect(figure.text == PeakReadout.text(forHeldPeak: 0.5))
    }

    @Test("a hold rising to a new figure notifies observers")
    func newFigureNotifies() {
        let figure = PeakFigure()
        figure.show(heldPeak: 0.5)
        #expect(notifications(of: figure) { figure.show(heldPeak: 0.9) } == 1)
    }
}

/// The shared display link's frame: one relay read stepping every capsule
/// and every readout figure, and a reset answered at once.
@Suite("MeterDisplayLink")
@MainActor
struct MeterDisplayLinkTests {
    /// A standing capsule's size.
    private let size = CGSize(width: 5, height: 110)

    /// A standing capsule over the test strip, sized, not yet registered.
    private func capsule(on displayLink: MeterDisplayLink) -> MeterCapsuleView {
        let view = MeterCapsuleView(displayLink: displayLink, subject: .strip(mic), axis: .vertical)
        view.frame = CGRect(origin: .zero, size: size)
        return view
    }

    @Test("a registered figure shows its subject's hold at once, before any frame")
    func registeredFigureShowsAtOnce() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0.5))
        let displayLink = MeterDisplayLink(relay: relay)
        let figure = PeakFigure()
        displayLink.register(figure, for: .strip(mic))
        #expect(figure.text == PeakReadout.text(forHeldPeak: 0.5))
    }

    @Test("a frame shows every registered figure its subject's hold")
    func frameUpdatesFigures() {
        let relay = MeterRelay()
        let displayLink = MeterDisplayLink(relay: relay)
        let strip = PeakFigure()
        let master = PeakFigure()
        displayLink.register(strip, for: .strip(mic))
        displayLink.register(master, for: .master)
        relay.fold(block(strip: 0.5, right: 1))
        displayLink.refresh(at: .now)
        #expect(strip.text == PeakReadout.text(forHeldPeak: 0.5))
        #expect(master.isOver)
    }

    @Test("an unregistered figure keeps what it showed")
    func unregisteredFigureStops() {
        let relay = MeterRelay()
        let displayLink = MeterDisplayLink(relay: relay)
        let figure = PeakFigure()
        displayLink.register(figure, for: .strip(mic))
        displayLink.unregister(figure)
        relay.fold(block(strip: 0.5))
        displayLink.refresh(at: .now)
        #expect(figure.text == nil)
    }

    @Test("a figure moved to another subject shows that subject's hold")
    func figureMovesSubject() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0.5, left: 1))
        let displayLink = MeterDisplayLink(relay: relay)
        let figure = PeakFigure()
        displayLink.register(figure, for: .strip(mic))
        displayLink.register(figure, for: .master)
        #expect(figure.isOver)
    }

    @Test("a reset clears the hold on the relay and on the subject's figures at once")
    func resetAnswersAtOnce() {
        let relay = MeterRelay()
        relay.fold(block(strip: 0.5, left: 0.7))
        let displayLink = MeterDisplayLink(relay: relay)
        let strip = PeakFigure()
        let master = PeakFigure()
        displayLink.register(strip, for: .strip(mic))
        displayLink.register(master, for: .master)
        displayLink.resetPeak(of: .strip(mic))
        #expect(relay.heldPeaks[mic] == nil)
        #expect(strip.text == nil)
        // The other subject's hold is untouched.
        #expect(master.text == PeakReadout.text(forHeldPeak: 0.7))
        displayLink.resetPeak(of: .master)
        #expect(relay.heldMasterPeak == 0)
        #expect(master.text == nil)
    }

    @Test("a frame moves a registered capsule: a full-scale reading fills it")
    func frameStepsCapsules() {
        let relay = MeterRelay()
        let displayLink = MeterDisplayLink(relay: relay)
        let view = capsule(on: displayLink)
        displayLink.register(view)
        relay.fold(block(strip: 1, rms: 1))
        displayLink.refresh(at: .now)
        #expect(!view.level.isHidden)
        #expect(view.level.frame == MeterCapsule.barRect(fraction: 1, in: size, axis: .vertical))
        #expect(!view.peakMarker.isHidden)
        #expect(view.peakMarker.frame == MeterCapsule.peakRect(fraction: 1, in: size, axis: .vertical))
    }

    @Test("a window with any part visible keeps the meters moving; a fully covered one pauses them")
    func pausesOnlyWhenNothingIsVisible() {
        #expect(!MeterDisplayLink.shouldPause(for: .visible))
        #expect(MeterDisplayLink.shouldPause(for: []))
    }

    @Test("a capsule in a window not on screen starts the link paused, and leaving the window stops it")
    func windowOffScreenStartsPaused() {
        let displayLink = MeterDisplayLink(relay: MeterRelay())
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = capsule(on: displayLink)
        #expect(!displayLink.isRunning)
        // Never ordered in, so no part of the window is visible.
        window.contentView?.addSubview(view)
        #expect(displayLink.isRunning)
        #expect(displayLink.isPaused)
        view.removeFromSuperview()
        #expect(!displayLink.isRunning)
        #expect(!displayLink.isPaused)
    }

    @Test("an unregistered capsule no longer moves")
    func unregisteredCapsuleStops() {
        let relay = MeterRelay()
        let displayLink = MeterDisplayLink(relay: relay)
        let view = capsule(on: displayLink)
        displayLink.register(view)
        displayLink.unregister(view)
        relay.fold(block(strip: 1, rms: 1))
        displayLink.refresh(at: .now)
        #expect(view.level.isHidden)
    }
}

/// The capsule's layers under explicit readings: the level stands on the
/// floor end, the zones stay put behind it, and silence draws nothing.
@Suite("MeterCapsuleView")
@MainActor
struct MeterCapsuleViewTests {
    /// A standing capsule's size.
    private let size = CGSize(width: 5, height: 110)

    /// A fixed instant, so the ballistics start fresh.
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    /// A standing capsule over the test strip.
    private func capsule() -> MeterCapsuleView {
        let view = MeterCapsuleView(
            displayLink: MeterDisplayLink(relay: MeterRelay()), subject: .strip(mic), axis: .vertical)
        view.frame = CGRect(origin: .zero, size: size)
        return view
    }

    /// A relay state carrying one strip reading.
    private func snapshot(peak: Float, rms: Float) -> MeterRelay.Snapshot {
        let relay = MeterRelay()
        relay.fold(block(strip: peak, rms: rms))
        return relay.snapshot
    }

    @Test("silence shows neither the level nor the peak marker")
    func silenceShowsNothing() {
        let view = capsule()
        view.show(snapshot(peak: 0, rms: 0), at: start)
        #expect(view.level.isHidden)
        #expect(view.peakMarker.isHidden)
    }

    @Test("a −30 dBFS level stands on the bottom and fills half the capsule")
    func halfScaleStandsOnTheBottom() {
        let view = capsule()
        // −30 dBFS is halfway up the −60…0 dBFS scale.
        let halfway = Float(pow(10, -30.0 / 20))
        view.show(snapshot(peak: halfway, rms: halfway), at: start)
        #expect(!view.level.isHidden)
        #expect(abs(view.level.frame.maxY - size.height) < 0.001)
        #expect(abs(view.level.frame.height - size.height / 2) < 0.001)
    }

    @Test("the zones stay fixed to the capsule whatever the level")
    func zonesStayFixed() {
        let view = capsule()
        let halfway = Float(pow(10, -30.0 / 20))
        view.show(snapshot(peak: halfway, rms: halfway), at: start)
        // In the capsule's space, the zones cover the whole capsule.
        let zonesInCapsule = view.zones.frame.offsetBy(dx: view.level.frame.minX, dy: view.level.frame.minY)
        #expect(abs(zonesInCapsule.minY) < 0.001)
        #expect(zonesInCapsule.size == size)
    }

    @Test("a standing capsule's zones run from the floor at the bottom to full scale at the top")
    func zonesRunUpward() {
        let view = capsule()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.zones.startPoint == CGPoint(x: 0, y: 1))
        #expect(view.zones.endPoint == .zero)
    }
}
