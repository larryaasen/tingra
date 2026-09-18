//
//  ToneGenerator.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Synchronization
import TingraEventBus
import TingraPlugInKit

/// The 440 Hz test tone audio generator (`--audio-generator tone`, see
/// CLI.md).
///
/// Buffers are synthesized on the injected clock's tick — one buffer per
/// tick, stamped with the tick's master clock time (CLOCK.md,
/// "Generators"). The sine phase is continuous across buffers (a running
/// phase accumulator, which is content, not timing — PTS always comes from
/// the clock) and across a retune, so changing the frequency mid-stream
/// never clicks.
///
/// The tone is the first input to **declare parameters** (PLUGINS.md,
/// Decision 15): ``frequencyParameter`` and ``levelParameter``, which a host
/// draws a settings pane from and applies through ``setParameters(_:)`` —
/// live, read by every running synthesizer at its next buffer. The
/// initializer's `frequency` is the value before any host applies one.
///
/// A class because the generator owns live stream state (the active audio
/// continuations `stop()` finishes, the tuning the synthesizers read).
public final class ToneGenerator: Input, Sendable {
    /// The generator's stable input identifier, the exact
    /// `--audio-generator` value.
    public static let inputID = InputID(rawValue: "tone")

    /// The declared frequency parameter: `frequencyHertz`, the audible band
    /// on a logarithmic scale, defaulting to the CLI's 440 Hz.
    public static let frequencyParameter = Parameter(
        key: "frequencyHertz",
        name: "Frequency",
        range: 20...20_000,
        defaultValue: 440,
        unit: "Hz",
        scale: .logarithmic
    )

    /// The declared level parameter: `levelDecibels`, peak level relative
    /// to full scale, from −60 dB to full scale, defaulting to
    /// ``defaultLevelDecibels``.
    public static let levelParameter = Parameter(
        key: "levelDecibels",
        name: "Level",
        range: -60...0,
        defaultValue: defaultLevelDecibels,
        unit: "dB"
    )

    /// The default peak level: half amplitude, the level the tone has
    /// always had, expressed in decibels (about −6 dB).
    public static let defaultLevelDecibels = 20 * log10(0.5)

    /// The frequency and level, in display order.
    public var parameters: [Parameter] { [Self.frequencyParameter, Self.levelParameter] }

    /// The stable input identifier (`tone`).
    public var id: InputID { Self.inputID }

    /// The user-facing name.
    public let name = "440 Hz Tone"

    /// Generators are their own input kind (see GLOSSARY.md).
    public let kind = InputKind.generator

    /// A test tone: audio only. This is what lets tone become a channel
    /// strip — the kind it shares with bars never could.
    public let media = InputMedia.audio

    /// The master clock (or a synthetic clock under test) whose tick paces
    /// buffer synthesis and stamps each buffer's PTS.
    private let clock: any EngineClock

    /// What the synthesizers read at every buffer: the frequency and the
    /// peak amplitude, as last applied.
    struct Tuning: Sendable, Equatable {
        /// The tone frequency in Hertz.
        var frequency: Double

        /// Peak amplitude of the tone, `0`…`1` of full scale.
        var amplitude: Float
    }

    /// The tuning shared between the generator and every live synthesizer:
    /// written by ``ToneGenerator/setParameters(_:)`` from whatever
    /// isolation the host calls it on, read once per buffer on each
    /// synthesis task. A class around the lock because a `Mutex` cannot be
    /// copied into the synthesizers, only referenced.
    final class SharedTuning: Sendable {
        /// The lock guarding the tuning.
        private let storage: Mutex<Tuning>

        /// Creates the shared tuning with its first value.
        init(_ tuning: Tuning) {
            storage = Mutex(tuning)
        }

        /// The tuning as last set.
        var current: Tuning { storage.withLock { $0 } }

        /// Replaces the tuning.
        func set(_ tuning: Tuning) {
            storage.withLock { $0 = tuning }
        }
    }

    /// The current tuning, shared with every live synthesizer.
    private let tuning: SharedTuning

    /// Samples per second (the CLI default, 48 kHz).
    private let sampleRate: Int

    /// Samples per synthesized buffer; also sets the tick cadence.
    private let samplesPerBuffer: Int

    /// The event bus, for reporting a synthesis stall and its recovery.
    /// Optional so unit tests construct a generator without one; when absent
    /// the generator simply reports nothing.
    private let eventBus: EventBus?

    /// The shared continuation/task plumbing every consumer's audio stream
    /// runs through.
    private let stream = GeneratorStreamCoordinator<CapturedAudio>()

    /// Creates a tone generator. Defaults match the CLI's audio defaults
    /// (440 Hz at 48 kHz, see CLI.md "Compression").
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis and stamps buffers.
    ///   - eventBus: The host's event bus, for synthesis diagnostics. Omit it
    ///     where those are not wanted (tests).
    ///   - frequency: The tone frequency in Hertz, until a host applies
    ///     ``frequencyParameter``.
    ///   - sampleRate: Samples per second.
    ///   - samplesPerBuffer: Samples per synthesized buffer.
    public init(
        clock: any EngineClock,
        eventBus: EventBus? = nil,
        frequency: Double = 440,
        sampleRate: Int = 48_000,
        samplesPerBuffer: Int = 1024
    ) {
        self.clock = clock
        self.eventBus = eventBus
        self.tuning = SharedTuning(
            Tuning(frequency: frequency, amplitude: Self.amplitude(forDecibels: Self.defaultLevelDecibels)))
        self.sampleRate = sampleRate
        self.samplesPerBuffer = samplesPerBuffer
    }

    /// The tuning the synthesizers currently read — what a host's pane
    /// applied, or the initializer's frequency at half amplitude.
    var currentTuning: Tuning { tuning.current }

    /// Applies the frequency and level from a host's payload, clamped to
    /// the declared ranges; an omitted key takes its declared default. Takes
    /// effect at every live stream's next buffer, phase-continuous.
    ///
    /// - Parameter parameters: The parameter payload.
    public func setParameters(_ parameters: [String: JSONValue]) async {
        let frequency = Self.frequencyParameter.clamped(Self.frequencyParameter.value(in: parameters))
        let level = Self.levelParameter.clamped(Self.levelParameter.value(in: parameters))
        tuning.set(Tuning(frequency: frequency, amplitude: Self.amplitude(forDecibels: level)))
    }

    /// The peak amplitude for a level in decibels relative to full scale.
    private static func amplitude(forDecibels decibels: Double) -> Float {
        Float(pow(10, decibels / 20))
    }

    /// Nothing to acquire — a generator has no device and cannot be denied
    /// authorization, so starting never throws.
    public func start() async throws {}

    /// One synthesized buffer per clock tick, stamped with the tick's time.
    /// The stream finishes when the tick stream ends, the consumer stops
    /// consuming, or ``stop()`` is called.
    public func audio() -> AsyncStream<CapturedAudio> {
        let tuning = self.tuning
        let sampleRate = self.sampleRate
        let samplesPerBuffer = self.samplesPerBuffer
        let tickDuration = CMTime(value: CMTimeValue(samplesPerBuffer), timescale: CMTimeScale(sampleRate))
        return stream.makeStream(
            clock: clock,
            tickInterval: tickDuration,
            inputID: id,
            eventBus: eventBus,
            makeRenderer: {
                ToneSynthesizer(tuning: tuning, sampleRate: sampleRate, samplesPerBuffer: samplesPerBuffer)
            },
            render: { (synthesizer, tickTime) throws(GeneratorSynthesisFailure) in
                try synthesizer.nextBuffer(at: tickTime)
            }
        )
    }

    /// Finishes every live audio stream. Safe to call more than once.
    public func stop() async {
        await stream.stopAll()
    }
}

/// Synthesizes successive sine buffers as mono float32 PCM `CMSampleBuffer`s
/// with phase continuity across buffers and across retunes. Confined to a
/// single synthesis task — never crosses an isolation boundary, so it needs
/// no `Sendable`.
private final class ToneSynthesizer {
    /// The generator's tuning, read once per buffer so a host's retune
    /// lands at the next buffer boundary.
    private let tuning: ToneGenerator.SharedTuning

    /// Samples per second.
    private let sampleRate: Int

    /// Samples per synthesized buffer.
    private let samplesPerBuffer: Int

    /// The running sine phase in radians, advanced per sample by the
    /// current frequency and wrapped at a full turn, so the waveform is
    /// continuous across buffers and a frequency change bends the wave
    /// rather than breaking it. Content state only — PTS always comes from
    /// the clock.
    private var phase: Double = 0

    /// The PCM format description shared by every buffer: mono float32 at
    /// the configured sample rate. Nil if creation was refused, in which case
    /// every tick throws ``GeneratorSynthesisFailure/audioFormatDescriptionUnavailable(_:)``.
    private let formatDescription: CMAudioFormatDescription?

    /// The `CMAudioFormatDescriptionCreate` status, kept so a synthesizer
    /// that never got a format description can still say why on every tick.
    private let formatStatus: OSStatus

    /// Creates a synthesizer and its shared format description.
    init(tuning: ToneGenerator.SharedTuning, sampleRate: Int, samplesPerBuffer: Int) {
        self.tuning = tuning
        self.sampleRate = sampleRate
        self.samplesPerBuffer = samplesPerBuffer
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatOut: CMAudioFormatDescription?
        formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatOut
        )
        self.formatDescription = formatOut
    }

    /// Synthesizes the next buffer with the given PTS.
    ///
    /// - Throws: A ``GeneratorSynthesisFailure`` if a Core Media allocation
    ///   was refused. The caller skips the tick — a generator problem must
    ///   never take down the pipeline — and reports the stall.
    func nextBuffer(at time: CMTime) throws(GeneratorSynthesisFailure) -> CapturedAudio {
        guard let formatDescription else { throw .audioFormatDescriptionUnavailable(formatStatus) }
        let current = tuning.current
        let phaseStep = 2 * Double.pi * current.frequency / Double(sampleRate)
        var samples = [Float](repeating: 0, count: samplesPerBuffer)
        for offset in samples.indices {
            samples[offset] = Float(sin(phase)) * current.amplitude
            phase += phaseStep
            if phase >= 2 * .pi { phase -= 2 * .pi }
        }

        let dataLength = samples.count * MemoryLayout<Float32>.size
        var blockOut: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockOut
        )
        guard blockStatus == noErr, let block = blockOut else {
            throw .audioBlockBufferUnavailable(blockStatus)
        }
        let replaceStatus = samples.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard replaceStatus == noErr else { throw .audioBlockBufferUnavailable(replaceStatus) }

        var sampleBufferOut: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: samples.count,
            presentationTimeStamp: time,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBufferOut
        )
        guard sampleStatus == noErr, let sampleBuffer = sampleBufferOut else {
            throw .audioSampleBufferUnavailable(sampleStatus)
        }
        return CapturedAudio(sampleBuffer: sampleBuffer)
    }
}
