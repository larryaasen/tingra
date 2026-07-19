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
/// While a meter consumer is attached (``meterReadings()``), the same walk
/// also measures every channel's consumed samples — pre-fader, before level,
/// pan, and mute — into one ``MeterBlock`` per tick: a byproduct of the mix,
/// never a second pass, and per-block data that never rides the event bus
/// (EVENTS.md; ARCHITECTURE.md, "Per-strip meters").
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

        /// The running mix task, while started.
        var mixTask: Task<Void, Never>?
    }

    /// One channel strip's live state: its controls and its queue.
    private struct ChannelState {
        /// The strip's linear gain (negative treated as `0`).
        var level: Double

        /// The strip's pan position (clamped to `-1`...`1` at the mix).
        var pan: Double

        /// Whether the strip is muted.
        var isMuted: Bool

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
    /// runs, measuring every strip's signal **pre-fader** — before level,
    /// pan, and mute; see ``MeterReading`` — as a byproduct of the same walk
    /// the tick already makes over every channel's samples, never a second
    /// pass. Readings are per-block data, so they ride this dedicated stream
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
    /// audio), sums the audible ones into a stereo block, and yields it
    /// stamped with the tick time. Missing samples are silence — an
    /// underrunning channel never stalls the block. While a meter consumer
    /// is attached, the same walk also measures each channel's consumed
    /// samples pre-fader and yields the tick's ``MeterBlock``.
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
                        if metering {
                            readings[id] = Self.meterReading(over: channel.queue, frames: take)
                        }
                        let gain = channel.isMuted ? 0 : Float(max(0, channel.level))
                        if gain > 0 {
                            let pan = Self.panGains(channel.pan)
                            let leftGain = gain * pan.left
                            let rightGain = gain * pan.right
                            if channel.queue.count == 1 {
                                // Mono spreads into both program channels through
                                // the pan gains — a constant-power panner.
                                let mono = channel.queue[0]
                                for i in 0..<take {
                                    left[i] += mono[i] * leftGain
                                    right[i] += mono[i] * rightGain
                                }
                            } else {
                                // Stereo (and wider) maps its first two channels
                                // through the pan gains — a balance: each channel
                                // is scaled, never folded into the other; the
                                // rest are dropped at the mix.
                                let sourceLeft = channel.queue[0]
                                let sourceRight = channel.queue[1]
                                for i in 0..<take {
                                    left[i] += sourceLeft[i] * leftGain
                                    right[i] += sourceRight[i] * rightGain
                                }
                            }
                        }
                        for c in channel.queue.indices {
                            channel.queue[c].removeFirst(take)
                        }
                        state.channels[id] = channel
                    }
                    let program = state.programContinuation.map { (left, right, $0) }
                    let meters = state.meterContinuation.map { (MeterBlock(time: tickTime, strips: readings), $0) }
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

    /// Measures one strip's meter reading over the samples a tick consumed:
    /// the peak is the largest absolute sample across the strip's source
    /// channels, the RMS the hotter channel's root-mean-square — both over
    /// exactly the `frames` consumed samples, so an underrunning strip
    /// meters the signal it delivered, never the silence that pads the
    /// block. Pre-fader by construction: the queue holds intake-normalized
    /// samples the strip's level, pan, and mute have not yet touched.
    ///
    /// - Parameters:
    ///   - queue: The strip's queued samples, channel-major.
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
