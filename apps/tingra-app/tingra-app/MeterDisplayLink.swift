//
//  MeterDisplayLink.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Observation
import QuartzCore

/// The one display link every meter on screen shares: each display frame it
/// reads the ``MeterRelay`` **once**, steps every ``MeterCapsuleView`` in the
/// same pass, and hands each ``PeakReadout`` its ``PeakFigure`` — which
/// changes only when the figure the readout shows does.
///
/// It exists because a `TimelineView` cannot draw a meter without
/// redrawing the window around it (ARCHITECTURE.md, "Meters off the SwiftUI
/// clock"). Any `TimelineView` scheduled a quarter second apart or closer
/// runs its window's whole SwiftUI graph at display rate: the graph's time
/// advances every frame, and every view's frame — 561 of them in the main
/// window, measured 2026-09-27 — is recomputed. The meters' `.animation`
/// timelines and the readouts' ten-hertz ones each did it alone, and
/// together cost the main window 120 full passes a second. Layers moved
/// from here never touch the graph, so while the meters run the window's
/// only SwiftUI work is a readout redrawing when its hold rises or resets.
///
/// **One** link rather than one per capsule, because each link's frame is a
/// Core Animation commit of its own: nine capsules on nine links measured
/// two to three times the CPU of one link stepping all nine, and the gap
/// grows with the window.
///
/// The link runs while any capsule is in a window, and stops with the last
/// one out. It also **pauses while that window is fully covered**: a
/// minimized window or a hidden app already stops a window's display link,
/// but a window buried under another kept it firing at display rate
/// (measured 2026-09-27), moving meters nobody could see. The pause follows
/// the window's occlusion state as it changes — an event, never a check per
/// frame — and costs the meters nothing they need: the holds are folded per
/// block in the relay whether anything draws or not, and the first frame
/// back shows the current levels. Every readout stands beside a capsule — a strip's above its
/// meter, the master's above the master meter — so the readouts ride the
/// capsules' link rather than keeping one of their own.
final class MeterDisplayLink: NSObject {
    /// The relay every meter reads.
    let relay: MeterRelay

    /// The capsules in a window, stepped every frame in the order they
    /// arrived.
    private var capsules: [MeterCapsuleView] = []

    /// The figure of each peak readout on screen and the hold it shows,
    /// keyed by the figure's identity.
    private var figures: [ObjectIdentifier: (subject: PeakSubject, figure: PeakFigure)] = [:]

    /// The display link, while any capsule is in a window.
    private var link: CADisplayLink?

    /// The task following the link's window in and out of view, while the
    /// link exists.
    private var occlusionTask: Task<Void, Never>?

    /// Whether the display link exists — some capsule is in a window.
    var isRunning: Bool {
        link != nil
    }

    /// Whether the running link is paused because its window is fully
    /// covered; false while no link exists.
    var isPaused: Bool {
        link?.isPaused ?? false
    }

    /// Creates a link over a relay; nothing runs until a capsule arrives.
    ///
    /// - Parameter relay: The relay the meters read.
    init(relay: MeterRelay) {
        self.relay = relay
    }

    /// Adds a capsule that just moved into a window, starting the display
    /// link from that window if it is the first. Adding a capsule twice is
    /// a no-op.
    ///
    /// - Parameter capsule: The capsule to step every frame.
    func register(_ capsule: MeterCapsuleView) {
        guard !capsules.contains(where: { $0 === capsule }) else { return }
        capsules.append(capsule)
        capsule.show(relay.snapshot, at: .now)
        guard link == nil, let window = capsule.window else { return }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        // Common modes, so the meters keep moving while the operator holds a
        // fader — a drag runs the event-tracking mode, not the default one.
        link.add(to: .main, forMode: .common)
        self.link = link
        followOcclusion(of: window)
    }

    /// Removes a capsule that left its window, stopping the display link
    /// with the last one.
    ///
    /// - Parameter capsule: The capsule to stop stepping.
    func unregister(_ capsule: MeterCapsuleView) {
        capsules.removeAll { $0 === capsule }
        guard capsules.isEmpty else { return }
        occlusionTask?.cancel()
        occlusionTask = nil
        link?.invalidate()
        link = nil
    }

    /// Whether the meters should pause for a window's occlusion state:
    /// whenever no part of the window is visible.
    ///
    /// - Parameter state: The window's occlusion state.
    /// - Returns: True when the window is fully covered, minimized, or
    ///   hidden.
    static func shouldPause(for state: NSWindow.OcclusionState) -> Bool {
        !state.contains(.visible)
    }

    /// Pauses the link for the window's state now, then follows each change
    /// of it — a window not yet on screen starts paused and resumes as it
    /// appears.
    ///
    /// - Parameter window: The window the link was made from.
    private func followOcclusion(of window: NSWindow) {
        // Made before the task starts, so a change in between is not missed.
        let changes = NotificationCenter.default.notifications(
            named: NSWindow.didChangeOcclusionStateNotification, object: window)
        link?.isPaused = Self.shouldPause(for: window.occlusionState)
        occlusionTask = Task { [weak self, weak window] in
            for await _ in changes {
                guard let self, let window else { return }
                self.link?.isPaused = Self.shouldPause(for: window.occlusionState)
            }
        }
    }

    /// Adds a readout's figure, or moves it to a new subject, and shows the
    /// subject's hold on it at once rather than a frame later.
    ///
    /// - Parameters:
    ///   - figure: The readout's figure.
    ///   - subject: Whose hold it shows.
    func register(_ figure: PeakFigure, for subject: PeakSubject) {
        figures[ObjectIdentifier(figure)] = (subject, figure)
        figure.show(heldPeak: subject.heldPeak(in: relay.snapshot))
    }

    /// Removes a readout's figure.
    ///
    /// - Parameter figure: The figure to stop updating.
    func unregister(_ figure: PeakFigure) {
        figures[ObjectIdentifier(figure)] = nil
    }

    /// Resets one subject's hold on the relay and shows the result on every
    /// figure of that subject at once, so a click on the readout answers in
    /// the same frame rather than the next.
    ///
    /// - Parameter subject: Whose hold to reset.
    func resetPeak(of subject: PeakSubject) {
        switch subject {
        case .strip(let id): relay.resetPeak(forInput: id)
        case .master: relay.resetMasterPeak()
        }
        let heldPeak = subject.heldPeak(in: relay.snapshot)
        for entry in figures.values where entry.subject == subject {
            entry.figure.show(heldPeak: heldPeak)
        }
    }

    /// One frame: the relay read once, every capsule stepped through its
    /// ballistics, and every figure shown its subject's hold — a figure
    /// whose hold has not moved costs one comparison.
    ///
    /// - Parameter date: The frame's timestamp, which the capsules' decay
    ///   follows.
    func refresh(at date: Date) {
        let snapshot = relay.snapshot
        for capsule in capsules {
            capsule.show(snapshot, at: date)
        }
        for entry in figures.values {
            entry.figure.show(heldPeak: entry.subject.heldPeak(in: snapshot))
        }
    }

    /// The display link's callback: one ``refresh(at:)`` per frame.
    ///
    /// - Parameter link: The firing display link.
    @objc private func step(_ link: CADisplayLink) {
        refresh(at: .now)
    }
}

/// What one ``PeakReadout`` shows: the held peak's figure and whether it is
/// an over, published only when either changes, so the readout redraws when
/// its hold rises or is reset and never otherwise (ARCHITECTURE.md, "Meters
/// off the SwiftUI clock").
@Observable
final class PeakFigure {
    /// The held peak in dBFS to one decimal with an explicit sign, or nil
    /// when nothing is held (``PeakReadout/text(forHeldPeak:)``).
    private(set) var text: String?

    /// Whether the hold reached full scale (``PeakReadout/isOver(_:)``).
    private(set) var isOver = false

    /// The raw hold the figure was last made from, so a frame whose hold
    /// has not moved — nearly every frame — formats nothing. Nil, like the
    /// figure it starts with.
    @ObservationIgnored private var shownPeak: Float?

    /// Creates a figure showing nothing held.
    init() {}

    /// Shows a hold: the figure is remade only when the raw hold moved, and
    /// each property is written only when its value changes, so observers
    /// hear of a change the readout can actually show — a hold rising within
    /// the same tenth of a decibel changes nothing.
    ///
    /// - Parameter peak: The subject's held peak, or nil when nothing is
    ///   held.
    func show(heldPeak peak: Float?) {
        guard peak != shownPeak else { return }
        shownPeak = peak
        let text = PeakReadout.text(forHeldPeak: peak)
        if text != self.text {
            self.text = text
        }
        let isOver = PeakReadout.isOver(peak)
        if isOver != self.isOver {
            self.isOver = isOver
        }
    }
}
