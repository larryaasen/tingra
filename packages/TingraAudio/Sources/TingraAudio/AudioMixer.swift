//
//  AudioMixer.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import CoreMedia
import Synchronization
import TingraEventBus
import TingraPlugInKit

/// The mixer: the audio surface of the engine, combining every audio input
/// into the program mix (GLOSSARY.md, "Mixer") — one ``ChannelStrip`` per
/// input, each with a level and a mute. It replaces the single-microphone
/// pass-through the CLI era streamed with a real mixing stage, the audio
/// counterpart of the video side's `Compositor`.
///
/// A **mix tick** paced by the injected clock produces one mixed program
/// audio block per ``MixFormat/blockFrames`` (CLOCK.md's tick model applied
/// to audio): each tick sums every unmuted strip's queued samples — scaled
/// by its level and placed by its pan (the equal-power law normalized to
/// unity at center; see ``panGains(_:)``) — into a stereo block stamped with
/// the tick's master clock time.
/// Because tick deadlines are absolute positions on the master clock
/// (`T0 + n × blockDuration`), consecutive blocks form a perfectly
/// contiguous, monotonic PTS sequence — exactly what the compression sinks
/// want, mirroring the program video frame's tick-time rule.
///
/// Each strip's incoming audio is normalized once, at channel intake
/// (``ChannelNormalizer``): float32, deinterleaved, at the mix rate. Mono
/// sources spread equally into both program channels; stereo sources map
/// left/right; channels past the first two are dropped. Within a channel the
/// queue is a FIFO capped at one second — a stalled or disconnected input
/// contributes silence (a stalled input never stalls the program), and a
/// drifting-fast input drops its oldest samples at the cap rather than
/// growing latency without bound. The mix is a float sum with no bus clamp:
/// float32 has headroom, and delivery saturates at compression.
///
/// Each strip's consumed samples pass through its **effect chain** in
/// signal order before anything else touches them — post-intake,
/// pre-fader (``setEffects(_:forInput:)``; ARCHITECTURE.md, "Audio effect
/// chains") — so the chain shapes what the meter reads and what the fader
/// rides.
///
/// While a meter consumer is attached (``meterReadings()``), the same walk
/// also measures every channel's consumed samples — pre-fader, after the
/// effect chain but before level, pan, and mute — into one ``MeterBlock``
/// per tick: a byproduct of the mix, never a second pass, and per-block
/// data that never rides the event bus (EVENTS.md; ARCHITECTURE.md,
/// "Per-strip meters").
///
/// Downstream of every strip sits one master stage: the **master fade**
/// (``setMasterFade(_:duration:)``), the audio half of **fade to black**
/// (GLOSSARY.md) — a latching ramp of everything leaving the mixer, down to
/// silence and back. It applies after every chain, level, pan, and mute, and
/// before the master reading above, so a faded-down master meters as silence
/// while every strip meter keeps showing its input delivering. Its picture
/// half is `Compositor.setFadeToBlack(_:duration:)`, which a caller owning
/// both drives alongside it.
///
/// The mixer emits from its first tick — silence before any strip delivers —
/// so the program mix, like the program video, is a live canvas at the tick
/// rate from the moment it starts. Level, pan, and mute changes are gesture-rate
/// controls and deliberately report no events (the `updateShot` rule,
/// EVENTS.md); observability comes from the app's `tap` events, and only
/// ``start()``/``stop()`` report `mixer.started`/`mixer.stopped`.
///
/// Ownership (ARCHITECTURE.md, "Frame ownership across the `Input` seam"):
/// each strip's fill task is the one holder of that input's captured
/// buffers, consuming each buffer entirely as it normalizes it into the
/// channel queue; mixed blocks are freshly allocated, so the rule carries
/// over to every block the mixer yields.
///
/// The mutating controls (``setChannelStrips(_:)``, ``setLevel(_:forInput:)``,
/// ``setPan(_:forInput:)``, ``setMuted(_:forInput:)``, ``start()``,
/// ``stop()``) are meant to be driven
/// from one context (the app's main actor); they are internally locked but
/// not designed for concurrent callers racing each other — the same contract
/// as the `Compositor`.
public final class AudioMixer: Sendable {
    /// The clock whose tick paces the mix (the master clock in production, a
    /// synthetic clock in tests).
    private let clock: any EngineClock

    /// The mix sample rate and block size every block is produced at.
    private let format: MixFormat

    /// The host's event bus, carrying the mixer's control-plane events
    /// (never per-block traffic — EVENTS.md).
    private let eventBus: EventBus

    /// The most queued frames a channel may hold — one second at the mix
    /// rate. Beyond it the oldest samples are dropped, bounding the latency
    /// a drifting-fast input can accumulate.
    private let queueCapacity: Int

    /// The mixer's live state behind a mutex — the fill tasks, the mix task,
    /// and the program-audio consumer all touch it from different tasks.
    private let state = Mutex(State())

    /// The mutable mixer state.
    private struct State {
        /// The live channels, keyed by input id, in no particular order —
        /// mixing is commutative, so strip order carries no meaning.
        var channels: [InputID: ChannelState] = [:]

        /// The single active program-audio consumer, while attached.
        var programContinuation: AsyncStream<CapturedAudio>.Continuation?

        /// The single active meter consumer, while attached — measurement
        /// only happens while this is non-nil, so an unwatched meter costs
        /// nothing.
        var meterContinuation: AsyncStream<MeterBlock>.Continuation?

        /// The **master fade** — the audio half of fade to black, open until
        /// the operator takes the program down (GLOSSARY.md, "Fade to
        /// black").
        var fade = MasterFade()

        /// The running mix task, while started.
        var mixTask: Task<Void, Never>?
    }

    /// The master fade's latching state and its ramp, counted in mix blocks
    /// the way the compositor's counts program ticks — two ramps on two
    /// cadences from one requested duration, landing within a block of each
    /// other (ARCHITECTURE.md, "Fade to black").
    /// The ramp is **counted in blocks and divided**, never accumulated as a
    /// running float, for the reason recorded on the compositor's twin:
    /// subtracting an uneven per-block step leaves a residue (`1` minus
    /// `1/3` three times lands on `1.1e-16`, not `0`), and a residue means
    /// ``isActive`` never goes false again — so after one fade cycle the mix
    /// would be scaled by `0.9999999999999999` on every block for the rest
    /// of the session instead of being left alone. Dividing an integer
    /// position by an integer total makes both endpoints exact, so bringing
    /// the master back up restores a **byte-identical** mix rather than an
    /// inaudibly-close one.
    struct MasterFade {
        /// The number of mix blocks a whole open-to-silent travel spans, at
        /// least one. Fixed for the travel, so a fade interrupted mid-ramp
        /// reverses at the same rate from wherever it had reached.
        var totalBlocks: Int = 1

        /// How far along that travel the master currently sits,
        /// `0`...`totalBlocks`.
        var position: Int = 0

        /// Where the ramp is heading — `totalBlocks` after a fade down, `0`
        /// after a fade up. The **latch**.
        var targetPosition: Int = 0

        /// The master's current linear gain, `1` (open) down to `0`
        /// (silent) — exact at both ends by construction.
        var gain: Double { 1 - Double(position) / Double(totalBlocks) }

        /// The gain this block ends at — where ``gain`` will be once the
        /// block has been rendered. Interpolating from `gain` to this across
        /// the block's samples is what keeps a scripted ramp free of the
        /// zipper a per-block step would produce; a strip's hand-ridden
        /// level needs no such thing.
        var endGain: Double {
            var next = self
            next.advance()
            return next.gain
        }

        /// Whether the master is anything other than fully open — the test
        /// for whether the fade pass has to run at all.
        var isActive: Bool { position != 0 || targetPosition != 0 }

        /// Whether the master is faded down or on its way there.
        var isFaded: Bool { targetPosition > 0 }

        /// Advances the ramp by one block, stopping on the target.
        mutating func advance() {
            if position < targetPosition {
                position += 1
            } else if position > targetPosition {
                position -= 1
            }
        }

        /// Points the ramp at silence or at unity over `totalBlocks` blocks,
        /// rescaling how far it has already travelled onto the new block
        /// count so an interrupted fade keeps the level it was at.
        ///
        /// - Parameters:
        ///   - faded: `true` to head for silence, `false` for unity.
        ///   - newTotal: The block count a whole travel spans (at least 1).
        mutating func retarget(faded: Bool, totalBlocks newTotal: Int) {
            if newTotal != totalBlocks {
                position = Int(((1 - gain) * Double(newTotal)).rounded())
                totalBlocks = newTotal
            }
            targetPosition = faded ? newTotal : 0
        }
    }

    /// One channel strip's live state: its controls and its queue.
    private struct ChannelState {
        /// The strip's linear gain (negative treated as `0`).
        var level: Double

        /// The strip's pan position (clamped to `-1`...`1` at the mix).
        var pan: Double

        /// Whether the strip is muted.
        var isMuted: Bool

        /// The strip's effect chain, in signal order (the chain *is* its
        /// array — GLOSSARY.md, "Channel strip"). Each tick's consumed
        /// samples pass through it in place, post-intake and pre-fader —
        /// before the meter and before level, pan, and mute — so the
        /// chain shapes what the fader rides and what the meter reads
        /// (ARCHITECTURE.md, "Audio effect chains").
        var effects: [any AudioEffect] = []

        /// Queued normalized samples, channel-major (one array per source
        /// channel, equal lengths) — the FIFO the mix tick consumes.
        var queue: [[Float]] = []

        /// The task draining the input's `audio()` stream into the queue.
        var fillTask: Task<Void, Never>?
    }

    /// Creates a mixer.
    ///
    /// - Parameters:
    ///   - clock: The clock whose tick paces the mix.
    ///   - format: The mix sample rate and block size (default 48 kHz,
    ///     1024-frame blocks).
    ///   - eventBus: The host's event bus.
    public init(
        clock: any EngineClock,
        format: MixFormat = MixFormat(),
        eventBus: EventBus
    ) {
        self.clock = clock
        self.format = format
        self.eventBus = eventBus
        self.queueCapacity = Int(format.sampleRate)
    }

    /// The program-audio stream: one mixed block per mix tick, PTS on the
    /// master clock. A new call replaces the previous consumer (finishing
    /// its stream), matching the one-consumer contract the media seams use.
    public func programAudio() -> AsyncStream<CapturedAudio> {
        AsyncStream { continuation in
            let previous = state.withLock { state in
                let previous = state.programContinuation
                state.programContinuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    /// The meter stream: one ``MeterBlock`` per mix tick while the mixer
    /// runs, measuring every strip's signal **pre-fader** — after the
    /// strip's effect chain, before level, pan, and mute; see
    /// ``MeterReading`` — as a byproduct of the same walk
    /// the tick already makes over every channel's samples, never a second
    /// pass. The same block carries the **post-fader** master reading
    /// (``StereoMeterReading``), measured on the summed program block once
    /// every strip has contributed. Readings are per-block data, so they ride this dedicated stream
    /// and never the event bus (EVENTS.md, control plane only). A new call
    /// replaces the previous consumer (finishing its stream) — the
    /// one-consumer contract of ``programAudio()``.
    public func meterReadings() -> AsyncStream<MeterBlock> {
        AsyncStream { continuation in
            let previous = state.withLock { state in
                let previous = state.meterContinuation
                state.meterContinuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    /// Sets the channel strips whose audio feeds the mix. Inputs must
    /// already be started (the mixer mixes; it does not own device
    /// lifecycle — the caller's policy decides whether a muted strip's
    /// device keeps capturing). Strips no longer present have their fill
    /// task cancelled and their queue cleared; newly present strips get a
    /// fill task normalizing their `audio()` into a queue; strips already
    /// present just take the new level and mute.
    ///
    /// - Parameter strips: The channel strips of the mix.
    public func setChannelStrips(_ strips: [ChannelStrip]) {
        let desiredIDs = Set(strips.map(\.input.id))
        // Snapshot the audio streams for genuinely new inputs outside the
        // lock: `audio()` finishes any previous consumer (one holder at a
        // time), so it must be called once per new input, never for one
        // already being drained.
        let trackedIDs = state.withLock { Set($0.channels.keys) }
        let newStreams = strips.filter { !trackedIDs.contains($0.input.id) }
            .map { ($0.input.id, $0.input.audio()) }
        let sampleRate = format.sampleRate

        let removedFillTasks: [Task<Void, Never>] = state.withLock { state in
            var removed: [Task<Void, Never>] = []
            for (id, channel) in state.channels where !desiredIDs.contains(id) {
                if let task = channel.fillTask { removed.append(task) }
                state.channels[id] = nil
            }
            for strip in strips {
                let id = strip.input.id
                if var existing = state.channels[id] {
                    existing.level = strip.level
                    existing.pan = strip.pan
                    existing.isMuted = strip.isMuted
                    state.channels[id] = existing
                }
            }
            for (id, stream) in newStreams {
                guard let strip = strips.first(where: { $0.input.id == id }) else { continue }
                var channel = ChannelState(level: strip.level, pan: strip.pan, isMuted: strip.isMuted)
                channel.fillTask = Task { [weak self] in
                    var normalizer = ChannelNormalizer(sampleRate: sampleRate)
                    for await audio in stream {
                        guard let samples = normalizer.normalize(audio) else { continue }
                        self?.enqueue(samples, for: id)
                    }
                }
                state.channels[id] = channel
            }
            return removed
        }
        for task in removedFillTasks {
            task.cancel()
        }
    }

    /// Sets one strip's level, applied from the next mix tick. Unknown ids
    /// are ignored (the strip was removed since the control was drawn — a
    /// stale gesture, not an error). Gesture-rate: deliberately reports no
    /// event (EVENTS.md; the `updateShot` rule).
    ///
    /// - Parameters:
    ///   - level: The strip's linear gain (negative treated as `0`).
    ///   - id: The strip's input id.
    public func setLevel(_ level: Double, forInput id: InputID) {
        state.withLock { $0.channels[id]?.level = level }
    }

    /// Sets one strip's pan position, applied from the next mix tick.
    /// Unknown ids are ignored, like ``setLevel(_:forInput:)``. Gesture-rate:
    /// deliberately reports no event (EVENTS.md; the `updateShot` rule).
    ///
    /// - Parameters:
    ///   - pan: The strip's pan position, `-1` (hard left) to `1` (hard
    ///     right); values outside that range are clamped.
    ///   - id: The strip's input id.
    public func setPan(_ pan: Double, forInput id: InputID) {
        state.withLock { $0.channels[id]?.pan = pan }
    }

    /// Sets one strip's mute, applied from the next mix tick. Unknown ids
    /// are ignored, like ``setLevel(_:forInput:)``.
    ///
    /// - Parameters:
    ///   - isMuted: Whether the strip is muted.
    ///   - id: The strip's input id.
    public func setMuted(_ isMuted: Bool, forInput id: InputID) {
        state.withLock { $0.channels[id]?.isMuted = isMuted }
    }

    /// Sets one strip's effect chain, applied from the next mix tick — a
    /// structural chain change (add, remove, reorder, or adopting a
    /// preset's authored chain), replacing the previous instances and
    /// their processing state. For a parameter edit on an existing slot
    /// use ``setEffectParameters(_:forEffectAt:forInput:)``, which keeps
    /// filter memory intact. Unknown ids are ignored, like
    /// ``setLevel(_:forInput:)``; deliberately reports no event (the
    /// `updateShot` rule — the app's `tap` events carry observability).
    ///
    /// - Parameters:
    ///   - effects: The strip's effect instances, in signal order.
    ///   - id: The strip's input id.
    public func setEffects(_ effects: [any AudioEffect], forInput id: InputID) {
        state.withLock { $0.channels[id]?.effects = effects }
    }

    /// Applies a parameter payload to one slot of a strip's effect chain,
    /// in place — the gesture-rate control for a dragging effect slider:
    /// the instance keeps its processing state (filter memory, envelopes),
    /// only its settings change from the next mix tick. Unknown ids and
    /// out-of-range slots are ignored (a stale gesture, not an error);
    /// deliberately reports no event, like ``setLevel(_:forInput:)``.
    ///
    /// - Parameters:
    ///   - parameters: The parameter values to apply.
    ///   - index: The effect's position in the strip's chain.
    ///   - id: The strip's input id.
    public func setEffectParameters(_ parameters: [String: JSONValue], forEffectAt index: Int, forInput id: InputID) {
        state.withLock { state in
            guard var channel = state.channels[id], channel.effects.indices.contains(index) else { return }
            channel.effects[index].setParameters(parameters)
            state.channels[id] = channel
        }
    }

    /// Fades the **master** — everything leaving the mixer once every channel
    /// strip has contributed (GLOSSARY.md, "Master") — down to silence over
    /// `duration`, or back up, and **latches** there.
    ///
    /// This is the audio half of **fade to black** (GLOSSARY.md), and it is
    /// deliberately not named for black: at the master there is no picture,
    /// only silence. The picture half is
    /// `Compositor.setFadeToBlack(_:duration:)`; the two engine libraries do
    /// not depend on each other, so a caller taking the whole program off air
    /// drives both (ARCHITECTURE.md, "Fade to black").
    ///
    /// It sits downstream of every strip's effect chain, level, pan, and
    /// mute, and upstream of the post-fader **master meter** — so while the
    /// master is faded down the master meter reads silence while every strip
    /// meter keeps showing its input delivering, pre-fader. That asymmetry is
    /// the point: the operator can see their microphone is live *and* see
    /// that nobody can hear it.
    ///
    /// Fading changes nothing about the strips and stops no device: a muted
    /// strip stays muted, an open one stays open, and bringing the master
    /// back up restores exactly the mix that was there.
    ///
    /// - Parameters:
    ///   - faded: `true` to fade the master to silence, `false` to bring it
    ///     back up. Calling it again with the value already in effect
    ///     re-times the ramp toward the same target and is otherwise
    ///     harmless.
    ///   - duration: The ramp length in seconds, for a full open-to-silent
    ///     travel (default: half a second, the broadcast-typical length a
    ///     dissolve uses). Clamped to at least one block, so a zero or
    ///     negative duration still completes on the next mix tick.
    public func setMasterFade(_ faded: Bool, duration: TimeInterval = AudioMixer.defaultMasterFadeDuration) {
        let blocks = Self.blockCount(for: duration, format: format)
        state.withLock { state in
            state.fade.retarget(faded: faded, totalBlocks: blocks)
        }
        eventBus.event(
            "master.fade",
            domain: .audio,
            params: [
                "state": .string(faded ? "silent" : "open"),
                "durationSeconds": .double(duration),
            ]
        )
    }

    /// Whether the master is faded down or on its way there — the latch
    /// ``setMasterFade(_:duration:)`` sets, not the ramp's current position.
    public var isMasterFaded: Bool {
        state.withLock { $0.fade.isFaded }
    }

    /// The master fade's default ramp length, matching the compositor's
    /// `Transition.defaultDissolveDuration` — the broadcast-typical half
    /// second — rather than inventing a second convention. It is declared
    /// here rather than imported because `TingraAudio` and
    /// `TingraComposition` are siblings that do not depend on each other.
    public static let defaultMasterFadeDuration: TimeInterval = 0.5

    /// Converts a fade duration in seconds to the whole number of mix blocks
    /// it spans — at least one, so a zero or negative duration still
    /// completes on the next tick rather than never finishing (the
    /// compositor's `tickCount(for:frameRate:)` rule, one cadence over).
    ///
    /// - Parameters:
    ///   - duration: The requested ramp length in seconds.
    ///   - format: The mix format whose block size and sample rate set the
    ///     cadence.
    /// - Returns: The block count the ramp spans.
    static func blockCount(for duration: TimeInterval, format: MixFormat) -> Int {
        let blocksPerSecond = format.sampleRate / Double(format.blockFrames)
        return max(1, Int((duration * blocksPerSecond).rounded()))
    }

    /// Starts the mix tick: the mixer sums and yields one block per tick
    /// until ``stop()`` — silence before any strip delivers. Idempotent — a
    /// second call while running does nothing.
    public func start() {
        let blockDuration = CMTime(
            value: CMTimeValue(format.blockFrames),
            timescale: CMTimeScale(format.sampleRate)
        )
        let clock = self.clock
        let format = self.format

        state.withLock { state in
            guard state.mixTask == nil else { return }
            state.mixTask = Task { [weak self] in
                for await tickTime in clock.tick(every: blockDuration) {
                    guard !Task.isCancelled, let self else { break }
                    self.mixBlock(at: tickTime, format: format)
                }
            }
        }
        eventBus.event(
            "mixer.started",
            domain: .audio,
            params: [
                "sampleRate": .int(Int(format.sampleRate)),
                "blockFrames": .int(format.blockFrames),
            ]
        )
    }

    /// Stops the mix tick, cancels every fill task, finishes the program and
    /// meter streams, and clears the channels. Safe to call more than once.
    public func stop() {
        let (mixTask, fillTasks, continuation, meterContinuation) = state.withLock { state in
            let taken = (
                state.mixTask, state.channels.values.compactMap(\.fillTask), state.programContinuation,
                state.meterContinuation
            )
            state.mixTask = nil
            state.channels.removeAll()
            state.programContinuation = nil
            state.meterContinuation = nil
            // The master fade is session state, so a stopped mixer never
            // comes back up silent — a show must not reopen faded down.
            state.fade = MasterFade()
            return taken
        }
        mixTask?.cancel()
        for task in fillTasks {
            task.cancel()
        }
        continuation?.finish()
        meterContinuation?.finish()
        eventBus.event("mixer.stopped", domain: .audio)
    }

    /// Runs one mix tick: consumes up to one block from every channel's
    /// queue (muted strips drain too, so unmuting never replays stale
    /// audio), passes each channel's consumed samples through its effect
    /// chain in signal order, sums the audible ones into a stereo block,
    /// and yields it stamped with the tick time. Missing samples are
    /// silence — an underrunning channel never stalls the block, and a
    /// channel that delivered nothing skips its chain (v1 effects are
    /// processors, not generators). While a meter consumer is attached,
    /// the same walk also measures each channel's consumed samples
    /// pre-fader — after the chain, before level, pan, and mute — and
    /// yields the tick's ``MeterBlock``. Last of all, while the **master
    /// fade** is anything but fully open, the summed block is scaled by the
    /// master's ramping gain — downstream of every strip and upstream of the
    /// post-fader master reading, both of which read the same summed arrays.
    private func mixBlock(at tickTime: CMTime, format: MixFormat) {
        let frames = format.blockFrames
        let output:
            (
                program: (left: [Float], right: [Float], continuation: AsyncStream<CapturedAudio>.Continuation)?,
                meters: (block: MeterBlock, continuation: AsyncStream<MeterBlock>.Continuation)?
            ) =
                state.withLock { state in
                    let metering = state.meterContinuation != nil
                    var readings: [InputID: MeterReading] = [:]
                    var left = [Float](repeating: 0, count: frames)
                    var right = [Float](repeating: 0, count: frames)
                    for id in Array(state.channels.keys) {
                        // A channel with nothing queued this tick meters at the
                        // floor — a consumer sees the floor, never a gap.
                        if metering { readings[id] = .floor }
                        guard var channel = state.channels[id], !channel.queue.isEmpty else { continue }
                        let available = channel.queue[0].count
                        let take = min(frames, available)
                        guard take > 0 else { continue }
                        // Consume the tick's samples out of the queue into a
                        // working block the strip's effect chain processes in
                        // place — post-intake, pre-fader, so the chain shapes
                        // what the meter reads and what the fader rides.
                        var block = channel.queue.map { Array($0.prefix(take)) }
                        for c in channel.queue.indices {
                            channel.queue[c].removeFirst(take)
                        }
                        for index in channel.effects.indices {
                            channel.effects[index].process(&block, sampleRate: format.sampleRate)
                        }
                        // An effect must preserve the block's shape; clamping
                        // to what actually came out keeps a misbehaving
                        // third-party effect from ever crashing the mix
                        // (the never-crash rule).
                        let use = min(take, block.map(\.count).min() ?? 0)
                        if metering, use > 0 {
                            readings[id] = Self.meterReading(over: block, frames: use)
                        }
                        let gain = channel.isMuted ? 0 : Float(max(0, channel.level))
                        if gain > 0, use > 0 {
                            let pan = Self.panGains(channel.pan)
                            let leftGain = gain * pan.left
                            let rightGain = gain * pan.right
                            if block.count == 1 {
                                // Mono spreads into both program channels through
                                // the pan gains — a constant-power panner.
                                let mono = block[0]
                                for i in 0..<use {
                                    left[i] += mono[i] * leftGain
                                    right[i] += mono[i] * rightGain
                                }
                            } else {
                                // Stereo (and wider) maps its first two channels
                                // through the pan gains — a balance: each channel
                                // is scaled, never folded into the other; the
                                // rest are dropped at the mix.
                                let sourceLeft = block[0]
                                let sourceRight = block[1]
                                for i in 0..<use {
                                    left[i] += sourceLeft[i] * leftGain
                                    right[i] += sourceRight[i] * rightGain
                                }
                            }
                        }
                        state.channels[id] = channel
                    }
                    // The master fade, last: downstream of every strip's
                    // chain, level, pan, and mute, and — because it runs
                    // before both the program yield and the master reading
                    // below, which read these same arrays — upstream of the
                    // post-fader master meter by construction, so the meter
                    // shows silence with no metering change at all
                    // (ARCHITECTURE.md, "Fade to black").
                    if state.fade.isActive {
                        Self.applyMasterFade(
                            &left, &right, from: state.fade.gain, to: state.fade.endGain, frames: frames)
                    }
                    state.fade.advance()
                    let program = state.programContinuation.map { (left, right, $0) }
                    // The master reading is taken here, on the summed block —
                    // after every strip's chain, level, pan, and mute, which
                    // is what makes it post-fader. Any master stage added
                    // later sits upstream of this point by construction.
                    let meters = state.meterContinuation.map { continuation in
                        (
                            MeterBlock(
                                time: tickTime,
                                strips: readings,
                                master: Self.masterReading(left: left, right: right)
                            ),
                            continuation
                        )
                    }
                    return (program, meters)
                }
        if let meters = output.meters {
            meters.continuation.yield(meters.block)
        }
        guard let block = output.program else { return }
        guard
            let mixed = Self.capturedAudio(
                left: block.left, right: block.right, at: tickTime, sampleRate: format.sampleRate)
        else { return }
        block.continuation.yield(mixed)
    }

    /// Applies the master fade across one block, interpolating the gain
    /// linearly from `start` to `end` sample by sample.
    ///
    /// Per **sample**, not per block, deliberately: a channel strip's level
    /// is a hand-ridden gesture where a per-block constant gain is right, but
    /// a scripted half-second ramp stepping once per block is a zipper — and
    /// the interpolation is one multiply-add on a block already being walked
    /// (ARCHITECTURE.md, "Fade to black").
    ///
    /// - Parameters:
    ///   - left: The summed left channel, faded in place.
    ///   - right: The summed right channel, faded in place.
    ///   - start: The master gain at the first sample.
    ///   - end: The master gain the block ends at.
    ///   - frames: The block's frame count (at least 1).
    static func applyMasterFade(
        _ left: inout [Float],
        _ right: inout [Float],
        from start: Double,
        to end: Double,
        frames: Int
    ) {
        guard frames > 0 else { return }
        let first = Float(start)
        let slope = Float(end - start) / Float(frames)
        for i in 0..<frames {
            let gain = first + slope * Float(i)
            left[i] *= gain
            right[i] *= gain
        }
    }

    /// Measures one strip's meter reading over the samples a tick consumed:
    /// the peak is the largest absolute sample across the strip's source
    /// channels, the RMS the hotter channel's root-mean-square — both over
    /// exactly the `frames` consumed samples, so an underrunning strip
    /// meters the signal it delivered, never the silence that pads the
    /// block. Pre-fader by construction: it measures the working block
    /// after intake normalization and the strip's effect chain, before the
    /// strip's level, pan, and mute have touched it.
    ///
    /// - Parameters:
    ///   - queue: The strip's consumed samples, channel-major.
    ///   - frames: The frame count the tick consumed (at least 1).
    /// - Returns: The strip's reading.
    static func meterReading(over queue: [[Float]], frames: Int) -> MeterReading {
        var peak: Float = 0
        var maxMeanSquare: Float = 0
        for channel in queue {
            var sumOfSquares: Float = 0
            for sample in channel.prefix(frames) {
                peak = max(peak, abs(sample))
                sumOfSquares += sample * sample
            }
            maxMeanSquare = max(maxMeanSquare, sumOfSquares / Float(frames))
        }
        return MeterReading(peak: peak, rms: maxMeanSquare.squareRoot())
    }

    /// Measures the master's reading over one tick's summed program block:
    /// each program channel's peak and RMS, kept **separate** rather than
    /// collapsed the way a strip's channels are — the master is where the
    /// operator judges the stereo image (ARCHITECTURE.md, "The monitor
    /// path"). Post-fader by construction: it measures the sum after every
    /// strip's effect chain, level, pan, and mute.
    ///
    /// - Parameters:
    ///   - left: The left program channel's samples.
    ///   - right: The right program channel's samples (same length).
    /// - Returns: The master's stereo reading.
    static func masterReading(left: [Float], right: [Float]) -> StereoMeterReading {
        StereoMeterReading(left: channelReading(over: left), right: channelReading(over: right))
    }

    /// Measures one program channel's peak and RMS over a whole block.
    /// A block of exact silence reads ``MeterReading/floor``.
    ///
    /// - Parameter samples: The channel's samples.
    /// - Returns: The channel's reading.
    private static func channelReading(over samples: [Float]) -> MeterReading {
        guard !samples.isEmpty else { return .floor }
        var peak: Float = 0
        var sumOfSquares: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            sumOfSquares += sample * sample
        }
        return MeterReading(peak: peak, rms: (sumOfSquares / Float(samples.count)).squareRoot())
    }

    /// The per-program-channel gains of a pan position: the equal-power
    /// (sine/cosine) law, normalized to unity at center (ARCHITECTURE.md,
    /// "Per-strip pan"). Center yields `(1, 1)` — a centered strip mixes
    /// exactly as it did before pan existed — and a hard-panned strip
    /// carries the law's +3 dB (√2) on its remaining channel, inside the
    /// float sum's headroom the same way a second unity strip is. Positions
    /// outside `-1`...`1` are clamped, the negative-level rule's sibling.
    ///
    /// - Parameter pan: The pan position, `-1` (hard left) to `1` (hard
    ///   right).
    /// - Returns: The left and right program-channel gains.
    static func panGains(_ pan: Double) -> (left: Float, right: Float) {
        // The symmetric sine form of the law: `sin(0)` is exactly zero where
        // `cos(π/2)` is not, so a hard-panned strip's silent channel is
        // exact silence, not a rounding residue.
        let clamped = min(1, max(-1, pan))
        let scale = 2.0.squareRoot()
        return (
            Float(scale * sin((1 - clamped) * .pi / 4)),
            Float(scale * sin((1 + clamped) * .pi / 4))
        )
    }

    /// Appends one intake's normalized samples to its channel's queue,
    /// dropping the oldest samples past the one-second cap. A chunk whose
    /// channel count differs from what is queued (a device format change)
    /// resets the queue to the new shape.
    private func enqueue(_ samples: [[Float]], for id: InputID) {
        state.withLock { state in
            guard var channel = state.channels[id] else { return }
            if channel.queue.count != samples.count {
                channel.queue = samples
            } else {
                for c in samples.indices {
                    channel.queue[c].append(contentsOf: samples[c])
                }
            }
            let overflow = (channel.queue.first?.count ?? 0) - queueCapacity
            if overflow > 0 {
                for c in channel.queue.indices {
                    channel.queue[c].removeFirst(overflow)
                }
            }
            state.channels[id] = channel
        }
    }

    /// Wraps one mixed stereo block as pipeline audio: a canonical (float32,
    /// deinterleaved) sample buffer whose PTS is the mix tick's master clock
    /// time. Returns nil when Core Media rejects the buffer — that block is
    /// skipped, never fatal.
    ///
    /// - Parameters:
    ///   - left: The left program channel's samples.
    ///   - right: The right program channel's samples (same length).
    ///   - time: The mix tick's time on the master clock.
    ///   - sampleRate: The mix sample rate.
    /// - Returns: The mixed block as ``CapturedAudio``, or nil.
    static func capturedAudio(
        left: [Float],
        right: [Float],
        at time: CMTime,
        sampleRate: Double
    ) -> CapturedAudio? {
        let frames = AVAudioFrameCount(left.count)
        guard
            frames > 0, left.count == right.count,
            let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
            let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frames),
            let channelData = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frames
        left.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channelData[0].update(from: base, count: source.count)
        }
        right.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channelData[1].update(from: base, count: source.count)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBufferOut: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: buffer.format.formatDescription,
                sampleCount: CMItemCount(frames),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBufferOut
            ) == noErr,
            let sampleBuffer = sampleBufferOut,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: buffer.audioBufferList
            ) == noErr
        else { return nil }
        return CapturedAudio(sampleBuffer: sampleBuffer)
    }
}
