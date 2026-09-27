//
//  StripMeter.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import Synchronization
import TingraAudio
import TingraEventBus
import TingraPlugInKit

/// A plain, lock-guarded holder for the latest meter readings: the writer
/// (the ``EngineModel``'s meter drain, off the main actor) and the reader
/// (the ``MeterDisplayLink`` moving every meter, on it) share one instance,
/// so the meters render at reading cadence without pushing a mix tick's worth of state
/// changes per block through SwiftUI observation — the ``ProgramFrameRelay``
/// pattern applied to audio (ARCHITECTURE.md, "Per-strip meters").
///
/// The relay also keeps each meter's **peak hold** (GLOSSARY.md, "Meter"):
/// the loudest sample since the operator last reset it, folded in
/// **per block** by ``fold(_:)`` rather than at draw time, so a hot block
/// that arrives while the window is occluded or the meters idle is held
/// all the same — the one thing a peak hold exists to catch
/// (ARCHITECTURE.md, "The console mixer").
nonisolated final class MeterRelay: Sendable {
    /// What the lock guards: the latest readings and the holds — and, read
    /// whole through ``snapshot``, what one display frame of meters draws.
    struct Snapshot: Sendable {
        /// The most recent mix tick's readings, keyed by input id.
        var latest: [InputID: MeterReading] = [:]

        /// The most recent mix tick's post-fader master reading.
        var master: StereoMeterReading = .floor

        /// Each strip's held peak, keyed by input id.
        var heldPeaks: [InputID: Float] = [:]

        /// The master's held peak.
        var heldMasterPeak: Float = 0
    }

    /// The guarded state. A lock rather than main-actor isolation so the
    /// meter drain writes off the main thread and never queues behind it
    /// (ARCHITECTURE.md, "Bounded frame streams"); the meters read under
    /// the same lock at display cadence.
    private let state = Mutex(Snapshot())

    /// Everything the relay holds, read under one lock — how the
    /// ``MeterDisplayLink`` reads it once per display frame for every meter
    /// and readout, rather than once per meter.
    var snapshot: Snapshot {
        state.withLock { $0 }
    }

    /// The most recent mix tick's readings, keyed by input id — empty before
    /// the first tick.
    var latest: [InputID: MeterReading] {
        state.withLock { $0.latest }
    }

    /// The most recent mix tick's **post-fader** master reading — what the
    /// master meter draws (GLOSSARY.md, "Master"). At the floor before the
    /// first tick.
    var master: StereoMeterReading {
        state.withLock { $0.master }
    }

    /// Each strip's held peak — the loudest sample magnitude metered since
    /// the strip's hold was last reset — keyed by input id. No entry until
    /// a strip has metered anything.
    var heldPeaks: [InputID: Float] {
        state.withLock { $0.heldPeaks }
    }

    /// The master's held peak: the louder channel's loudest sample since
    /// the master's hold was last reset. `0` until anything is metered.
    var heldMasterPeak: Float {
        state.withLock { $0.heldMasterPeak }
    }

    /// Creates an empty relay.
    init() {}

    /// Takes one mix tick's block: the latest readings replace the previous
    /// tick's, and every peak folds into its hold.
    ///
    /// - Parameter block: The tick's meter block.
    func fold(_ block: MeterBlock) {
        state.withLock { state in
            state.latest = block.strips
            state.master = block.master
            for (id, reading) in block.strips {
                state.heldPeaks[id] = max(state.heldPeaks[id] ?? 0, reading.peak)
            }
            state.heldMasterPeak = max(state.heldMasterPeak, block.master.left.peak, block.master.right.peak)
        }
    }

    /// Resets one strip's peak hold, so the readout starts over from the
    /// next block.
    ///
    /// - Parameter id: The strip's input id.
    func resetPeak(forInput id: InputID) {
        state.withLock { $0.heldPeaks[id] = nil }
    }

    /// Resets the master's peak hold.
    func resetMasterPeak() {
        state.withLock { $0.heldMasterPeak = 0 }
    }
}

/// The subject of a ``PeakReadout``: one strip's hold, or the master's.
enum PeakSubject: Equatable {
    /// A channel strip's hold, by input id.
    case strip(InputID)

    /// The master's hold.
    case master

    /// The `id` param the readout's reset `tap` reports.
    var tapID: String {
        switch self {
        case .strip(let id): id.rawValue
        case .master: "master"
        }
    }

    /// The subject's held peak in one read of the relay, or nil when
    /// nothing has been metered since the last reset.
    ///
    /// - Parameter snapshot: The relay's state.
    /// - Returns: The held sample magnitude, or nil.
    func heldPeak(in snapshot: MeterRelay.Snapshot) -> Float? {
        switch self {
        case .strip(let id): snapshot.heldPeaks[id]
        case .master: snapshot.heldMasterPeak > 0 ? snapshot.heldMasterPeak : nil
        }
    }
}

/// A meter's **peak hold** readout (GLOSSARY.md, "Meter"): the held peak in
/// dBFS to one decimal above the meter, `−∞` until anything is metered,
/// and **red once the hold reached full scale** — a sample magnitude of 1
/// or more, an over. Clicking it resets the hold, reporting `meterPeak.reset`
/// with the subject's id; nothing else resets one
/// (ARCHITECTURE.md, "The console mixer").
///
/// Observes a ``PeakFigure`` the shared ``MeterDisplayLink`` updates, which
/// changes only when the figure or its over state does — so the readout
/// redraws when its hold rises or is reset, and never on a clock. It used
/// to sample the relay in a ten-hertz `TimelineView`, which alone kept the
/// whole main window updating at display rate (ARCHITECTURE.md, "Meters off
/// the SwiftUI clock").
struct PeakReadout: View {
    /// The link that keeps the readout's figure current.
    let displayLink: MeterDisplayLink

    /// Whose hold the readout shows.
    let subject: PeakSubject

    /// The bus the reset's `tap` is reported on.
    let eventBus: EventBus

    /// The figure the readout shows, owned here and kept current by the
    /// link while the readout is on screen.
    @State private var figure = PeakFigure()

    /// A sample magnitude at or above which a hold reads as an over — full
    /// scale, 0 dBFS.
    static let overThreshold: Float = 1

    /// The readout: the figure as a plain button that resets the hold.
    var body: some View {
        let text = figure.text
        let isOver = figure.isOver
        Button {
            eventBus.tap("meterPeak.reset", domain: .audio, params: ["id": .string(subject.tapID)])
            displayLink.resetPeak(of: subject)
        } label: {
            text.map { Text($0) } ?? Text("−∞", comment: "Peak readout when nothing has been metered yet")
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isOver ? AnyShapeStyle(.red) : text == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
        )
        .monospacedDigit()
        .help(Text("Peak (click to reset)", comment: "Help tag on a meter's peak hold readout"))
        .accessibilityLabel(Text("Peak", comment: "Accessibility label of a meter's peak hold readout"))
        .accessibilityValue(accessibilityValue(figure: text, isOver: isOver))
        .onAppear { displayLink.register(figure, for: subject) }
        .onChange(of: subject) { displayLink.register(figure, for: subject) }
        .onDisappear { displayLink.unregister(figure) }
    }

    /// What VoiceOver reads for the figure: the figure itself, marked as an
    /// over when the color says so, since color must not be the only signal.
    private func accessibilityValue(figure: String?, isOver: Bool) -> Text {
        guard let figure else {
            return Text("−∞", comment: "Peak readout when nothing has been metered yet")
        }
        return isOver
            ? Text("\(figure), over", comment: "Accessibility value of a peak hold that reached full scale")
            : Text(figure)
    }

    /// The readout's figure for a held peak: its dBFS to one decimal with
    /// an explicit sign, or nil when nothing is held (a nil or silent
    /// peak).
    ///
    /// - Parameter peak: The held sample magnitude, or nil.
    /// - Returns: The formatted figure, or nil.
    static func text(forHeldPeak peak: Float?) -> String? {
        guard let peak, peak > 0 else { return nil }
        return FaderScale.readout(forGain: Double(peak))
    }

    /// Whether a held peak reads as an over — at or above full scale.
    ///
    /// - Parameter peak: The held sample magnitude, or nil.
    /// - Returns: True at or above ``overThreshold``.
    static func isOver(_ peak: Float?) -> Bool {
        guard let peak else { return false }
        return peak >= overThreshold
    }
}

/// One channel strip's meter (GLOSSARY.md, "Meter"): a capsule **standing
/// beside the strip's fader** over the same travel — the console's
/// meter-beside-fader arrangement (ARCHITECTURE.md, "The console mixer") —
/// showing the strip's **pre-fader** signal: an RMS bar over broadcast
/// green/yellow/red zones with a decayed peak marker. Display only: it
/// reports no events and edits nothing; under the app's mute-stops-device
/// policy a muted strip's meter rests at the floor because no samples
/// arrive (app policy, not meter semantics — ARCHITECTURE.md, "Per-strip
/// meters").
///
/// The meter's layers are moved by the shared ``MeterDisplayLink`` each
/// display frame, sampling the ``MeterRelay`` — readings never drive
/// SwiftUI observation, the preview's `MTKView` rule applied to audio
/// display, and its motion never runs SwiftUI's graph (ARCHITECTURE.md,
/// "Meters off the SwiftUI clock") — with its ballistics applied at draw
/// time (``MeterBallistics``).
struct StripMeter: View {
    /// The link that moves the meter.
    let displayLink: MeterDisplayLink

    /// The strip's input id — the relay key.
    let id: InputID

    /// The meter body: one standing capsule over the strip's pre-fader
    /// reading, as tall as the fader beside it.
    var body: some View {
        MeterCapsule(displayLink: displayLink, subject: .strip(id), thickness: 6, axis: .vertical)
            .frame(height: MasterMeter.length)
            .help(Text("Meter", comment: "Help tag and accessibility label of a channel strip's meter"))
            .accessibilityLabel(
                Text("Meter", comment: "Help tag and accessibility label of a channel strip's meter"))
    }
}

/// The master's meter (GLOSSARY.md, "Master"): two capsules showing the
/// program mix **post-fader** — after every strip's effect chain, level,
/// pan, and mute — one per program channel.
///
/// Stereo where ``StripMeter`` is a single bar, because the master is where
/// the operator judges the stereo image: a hard-panned strip leaving one
/// side dead is exactly what this meter exists to reveal (ARCHITECTURE.md,
/// "The monitor path"). Display only, like the strip meter — no `tap`s,
/// nothing to click.
///
/// The capsules stand **vertically**, left beside right, filling bottom to
/// top: the master is a column at the mixer panel's trailing edge, its meter
/// beside the monitor fader the way a console's master meter stands beside
/// its fader, both over one ``length``.
struct MasterMeter: View {
    /// The link that moves the meter.
    let displayLink: MeterDisplayLink

    /// The meter's travel in points — shared by every fader and meter on the
    /// panel, the strips' and the monitor's, so they all read against one
    /// length.
    static let length: CGFloat = 120

    /// The master meter body: the left channel beside the right, standing.
    var body: some View {
        HStack(spacing: 3) {
            MeterCapsule(displayLink: displayLink, subject: .masterLeft, thickness: 5, axis: .vertical)
            MeterCapsule(displayLink: displayLink, subject: .masterRight, thickness: 5, axis: .vertical)
        }
        .frame(height: Self.length)
        .help(Text("Master meter", comment: "Help tag and accessibility label of the master's meter"))
        .accessibilityLabel(
            Text("Master meter", comment: "Help tag and accessibility label of the master's meter"))
    }
}

/// One meter capsule: an RMS bar over broadcast green/yellow/red zones with
/// a decayed peak marker, moved at display cadence.
///
/// Shared by ``StripMeter`` and ``MasterMeter`` so the scale, the zone
/// boundaries, and the ballistics can never drift between the two meters an
/// operator reads side by side. It draws with a layer-backed
/// ``MeterCapsuleView`` the shared ``MeterDisplayLink`` moves every display
/// frame, reading the relay itself — so readings never pass through SwiftUI
/// observation, the `MTKView` preview's rule applied to audio display
/// (ARCHITECTURE.md, "Per-strip meters"), and the meter's motion never runs
/// SwiftUI's graph: the `TimelineView` it was drawn in until 2026-09-27
/// recomputed every view in the main window every frame (ARCHITECTURE.md,
/// "Meters off the SwiftUI clock").
///
/// The capsule fills along one ``axis``: bottom to top standing beside a
/// fader (every meter on the panel since the console layout), or left to
/// right lying down — the same scale and zones either way, only the
/// direction differs. The geometry below is the view's, unit-tested here.
struct MeterCapsule: NSViewRepresentable {
    /// The link that moves the capsule.
    let displayLink: MeterDisplayLink

    /// Whose reading the capsule shows.
    let subject: MeterSubject

    /// The capsule's thickness in points — its height lying horizontally,
    /// its width standing vertically.
    let thickness: CGFloat

    /// The axis the capsule fills along: `.horizontal` fills from the
    /// leading edge, `.vertical` from the bottom.
    var axis: Axis = .horizontal

    /// Makes the capsule's view; it starts moving once it is in a window.
    func makeNSView(context: Context) -> MeterCapsuleView {
        MeterCapsuleView(displayLink: displayLink, subject: subject, axis: axis)
    }

    /// Carries a changed subject or axis to the view.
    func updateNSView(_ nsView: MeterCapsuleView, context: Context) {
        nsView.subject = subject
        nsView.axis = axis
    }

    /// Sizes the capsule: ``thickness`` across its axis, whatever it is
    /// offered along it — the frame the `Canvas` capsule set on itself.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeterCapsuleView, context: Context) -> CGSize? {
        let offered = proposal.replacingUnspecifiedDimensions()
        switch axis {
        case .horizontal: return CGSize(width: offered.width, height: thickness)
        case .vertical: return CGSize(width: thickness, height: offered.height)
        }
    }

    /// The RMS bar for a fill `fraction` (`0`…`1`) of a capsule of `size`:
    /// from the leading edge rightward lying down, from the bottom upward
    /// standing — a meter fills toward full scale, which is up, never down.
    static func barRect(fraction: Double, in size: CGSize, axis: Axis) -> CGRect {
        switch axis {
        case .horizontal:
            return CGRect(x: 0, y: 0, width: size.width * fraction, height: size.height)
        case .vertical:
            let height = size.height * fraction
            return CGRect(x: 0, y: size.height - height, width: size.width, height: height)
        }
    }

    /// The peak marker for a peak `fraction`: a one-point line across the
    /// capsule at the peak's position, held one point inside the full-scale
    /// end so a full-scale peak stays visible rather than clipping away.
    static func peakRect(fraction: Double, in size: CGSize, axis: Axis) -> CGRect {
        switch axis {
        case .horizontal:
            let x = min(size.width * fraction, size.width - 1)
            return CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)
        case .vertical:
            let y = max(size.height * (1 - fraction), 1)
            return CGRect(x: 0, y: y - 0.5, width: size.width, height: 1)
        }
    }

    /// The zone gradient's line for a capsule of `size`: from the floor end
    /// to the full-scale end along the fill axis, so the red zone sits at the
    /// right lying down and at the top standing.
    static func zoneLine(in size: CGSize, axis: Axis) -> (start: CGPoint, end: CGPoint) {
        switch axis {
        case .horizontal:
            return (.zero, CGPoint(x: size.width, y: 0))
        case .vertical:
            return (CGPoint(x: 0, y: size.height), .zero)
        }
    }
}

/// The meter's draw-time ballistics: **instant attack** (a rising signal
/// jumps the display immediately — the operator must never miss a hot
/// block) with a **20 dB per second** decay — between IEC PPM's ~12 dB/s
/// and fast digital meters' ~40 dB/s: brisk enough to track speech, slow
/// enough to read. Ballistics live here, not in the engine, because decay
/// is a display convention — the engine's readings stay raw per-block truth
/// (ARCHITECTURE.md, "Per-strip meters").
@MainActor
final class MeterBallistics {
    /// The displayed RMS level in dBFS (`-.infinity` at the floor).
    private var rms: Double = -.infinity

    /// The displayed peak level in dBFS (`-.infinity` at the floor).
    private var peak: Double = -.infinity

    /// The previous draw's timestamp, so the decay follows real elapsed
    /// time rather than a frame count.
    private var lastDrawn: Date?

    /// The decay rate, in dB per second.
    private static let decayPerSecond: Double = 20

    /// The dBFS level the meter's scale bottoms out at.
    private static let floorDecibels: Double = -60

    /// Creates ballistics resting at the floor.
    init() {}

    /// Advances the decay to `date`, folds in the latest reading (attack is
    /// instant — the reading wins whenever it is louder than the decayed
    /// display), and returns the display fractions on the meter's scale
    /// (`0` at the −60 dBFS floor, `1` at full scale).
    ///
    /// - Parameters:
    ///   - reading: The latest per-block reading from the relay.
    ///   - date: The draw's timestamp.
    /// - Returns: The RMS bar's and the peak marker's fill fractions.
    func smoothed(_ reading: MeterReading, at date: Date) -> (rms: Double, peak: Double) {
        let decay = Self.decayPerSecond * (lastDrawn.map { date.timeIntervalSince($0) } ?? 0)
        lastDrawn = date
        rms = max(Self.decibels(reading.rms), rms - decay)
        peak = max(Self.decibels(reading.peak), peak - decay)
        return (Self.fraction(rms), Self.fraction(peak))
    }

    /// A linear sample magnitude in dBFS (`-.infinity` for silence).
    private static func decibels(_ value: Float) -> Double {
        value > 0 ? 20 * log10(Double(value)) : -.infinity
    }

    /// A dBFS level as a fill fraction of the meter's −60…0 scale, clamped
    /// to `0`...`1`.
    private static func fraction(_ decibels: Double) -> Double {
        min(1, max(0, 1 - decibels / floorDecibels))
    }
}
