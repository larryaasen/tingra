//
//  MeterCapsuleView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import QuartzCore
import SwiftUI
import TingraAudio
import TingraPlugInKit

/// What one meter capsule shows: a strip's pre-fader reading, or one side
/// of the master's post-fader reading.
enum MeterSubject: Equatable {
    /// A channel strip's reading, by input id.
    case strip(InputID)

    /// The master's left channel.
    case masterLeft

    /// The master's right channel.
    case masterRight

    /// The subject's reading in one read of the relay — the floor for a
    /// strip that has not metered anything.
    ///
    /// - Parameter snapshot: The relay's state for this frame.
    /// - Returns: The reading to draw.
    func reading(in snapshot: MeterRelay.Snapshot) -> MeterReading {
        switch self {
        case .strip(let id): snapshot.latest[id] ?? .floor
        case .masterLeft: snapshot.master.left
        case .masterRight: snapshot.master.right
        }
    }
}

/// The layer-backed view a ``MeterCapsule`` draws with: the capsule track,
/// the zone gradient clipped to the RMS level, and the peak marker, each a
/// Core Animation layer the shared ``MeterDisplayLink`` moves every display
/// frame — so a meter's motion never passes through SwiftUI's graph
/// (ARCHITECTURE.md, "Meters off the SwiftUI clock").
///
/// Flipped, so the layers share SwiftUI's top-left coordinate space and
/// ``MeterCapsule``'s geometry helpers place them unchanged. Display only:
/// it takes no clicks, so the pointer — and the help tag SwiftUI attaches —
/// belong to the hosting view, as they did when the capsule was a `Canvas`.
final class MeterCapsuleView: NSView {
    /// The link that steps the capsule while it is in a window.
    private let displayLink: MeterDisplayLink

    /// Whose reading the capsule shows.
    var subject: MeterSubject

    /// The axis the capsule fills along: `.horizontal` from the leading
    /// edge, `.vertical` from the bottom.
    var axis: Axis {
        didSet {
            guard axis != oldValue else { return }
            needsLayout = true
        }
    }

    /// The RMS level: a clip whose frame is the bar, holding the zone
    /// gradient still behind it, so the zones sit at fixed positions and
    /// only the bar's extent moves.
    let level = CALayer()

    /// The broadcast zone gradient, sized to the whole capsule inside
    /// ``level``.
    let zones = CAGradientLayer()

    /// The one-point decayed peak marker.
    let peakMarker = CALayer()

    /// The draw-time ballistics, one per capsule.
    private let ballistics = MeterBallistics()

    /// The fractions last shown, kept so a resize re-places the layers and
    /// an unchanged frame — a silent meter resting at the floor — commits
    /// nothing.
    private var shown: (rms: Double, peak: Double) = (0, 0)

    /// The broadcast zones over the meter's −60…0 dBFS scale: green through
    /// −20 dBFS, yellow through −6, red above, blended across the
    /// boundaries — the gradient is clipped to the current level, so the
    /// zones sit at fixed positions.
    private static let zoneStops: [(color: NSColor, location: Double)] = [
        (.systemGreen, 0),
        (.systemGreen, 0.62),
        (.systemYellow, 0.70),
        (.systemYellow, 0.87),
        (.systemRed, 0.95),
        (.systemRed, 1),
    ]

    /// Core Animation's implicit animations turned off for every key a
    /// refresh or an appearance change touches: the meter moves at display
    /// cadence under its own ballistics, and a quarter-second implicit
    /// animation would smear every frame.
    private static let immediate: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(),
        "backgroundColor": NSNull(), "colors": NSNull(),
        "startPoint": NSNull(), "endPoint": NSNull(),
    ]

    /// Creates a capsule over a subject; it starts moving once it is in a
    /// window.
    ///
    /// - Parameters:
    ///   - displayLink: The shared link that steps it.
    ///   - subject: Whose reading it shows.
    ///   - axis: The axis it fills along.
    init(displayLink: MeterDisplayLink, subject: MeterSubject, axis: Axis) {
        self.displayLink = displayLink
        self.subject = subject
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        zones.locations = Self.zoneStops.map { NSNumber(value: $0.location) }
        for sublayer in [level, zones, peakMarker] {
            sublayer.actions = Self.immediate
        }
        level.masksToBounds = true
        level.isHidden = true
        level.addSublayer(zones)
        peakMarker.isHidden = true
        layer?.addSublayer(level)
        layer?.addSublayer(peakMarker)
        needsDisplay = true
    }

    /// Not supported: the capsule is only made in code.
    required init?(coder: NSCoder) {
        nil
    }

    /// Top-left origin, SwiftUI's, so the geometry helpers apply unchanged.
    override var isFlipped: Bool {
        true
    }

    /// The colors are set in ``updateLayer()`` rather than drawn.
    override var wantsUpdateLayer: Bool {
        true
    }

    /// Never the target of a click or a hover: the meter is display only.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Starts stepping in a window and stops outside one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            displayLink.unregister(self)
        } else {
            displayLink.register(self)
        }
    }

    /// Resolves the dynamic colors for the current appearance: the track is
    /// the quaternary label color and the peak marker the label color, as
    /// the `Canvas` drew them with `.quaternary` and `.primary`.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        zones.colors = Self.zoneStops.map(\.color.cgColor)
        peakMarker.backgroundColor = NSColor.labelColor.cgColor
    }

    /// Re-resolves the colors when the appearance changes, light to dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Rounds the track to the new size, points the zones along the axis,
    /// and re-places the level and marker for it.
    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        let unit = MeterCapsule.zoneLine(in: CGSize(width: 1, height: 1), axis: axis)
        zones.startPoint = unit.start
        zones.endPoint = unit.end
        place(shown)
    }

    /// Steps the ballistics to `date` over the subject's reading and moves
    /// the layers — unless the displayed fractions did not change, the
    /// resting state of a silent meter, which then commits nothing.
    ///
    /// - Parameters:
    ///   - snapshot: The relay's state for this frame.
    ///   - date: The frame's timestamp.
    func show(_ snapshot: MeterRelay.Snapshot, at date: Date) {
        let smoothed = ballistics.smoothed(subject.reading(in: snapshot), at: date)
        guard smoothed != shown else { return }
        shown = smoothed
        place(smoothed)
    }

    /// Places the level and the marker for display fractions on the
    /// meter's scale, hiding each at the floor as the `Canvas` skipped
    /// drawing it.
    ///
    /// - Parameter fractions: The RMS bar's and the peak marker's fill
    ///   fractions, `0`…`1`.
    private func place(_ fractions: (rms: Double, peak: Double)) {
        let size = bounds.size
        level.isHidden = fractions.rms <= 0
        if fractions.rms > 0 {
            let bar = MeterCapsule.barRect(fraction: fractions.rms, in: size, axis: axis)
            level.frame = bar
            zones.frame = CGRect(origin: CGPoint(x: -bar.minX, y: -bar.minY), size: size)
        }
        peakMarker.isHidden = fractions.peak <= 0
        if fractions.peak > 0 {
            peakMarker.frame = MeterCapsule.peakRect(fraction: fractions.peak, in: size, axis: axis)
        }
    }
}
