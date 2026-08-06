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
import TingraEventBus
import TingraPlugInKit

/// The 440 Hz test tone audio generator (`--audio-generator tone`, see
/// CLI.md).
///
/// Buffers are synthesized on the injected clock's tick — one buffer per
/// tick, stamped with the tick's master clock time (CLOCK.md,
/// "Generators"). The sine phase is continuous across buffers (derived from
/// the running sample position within the stream, which is content, not
/// timing — PTS always comes from the clock).
///
/// A class because the generator owns live stream state (the active audio
/// continuations `stop()` finishes); configuration plumbing arrives with
/// the program pipeline at roadmap step 3.
public final class ToneGenerator: Input, Sendable {
    /// The generator's stable input identifier, the exact
    /// `--audio-generator` value.
    public static let inputID = InputID(rawValue: "tone")

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

    /// The tone frequency in Hertz.
    private let frequency: Double

    /// Samples per second (the CLI default, 48 kHz).
    private let sampleRate: Int

    /// Samples per synthesized buffer; also sets the tick cadence.
    private let samplesPerBuffer: Int

    /// Peak amplitude of the tone, comfortably below full scale.
    private let amplitude: Float

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
    ///   - frequency: The tone frequency in Hertz.
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
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.samplesPerBuffer = samplesPerBuffer
        self.amplitude = 0.5
    }

    /// Nothing to acquire — a generator has no device and cannot be denied
    /// authorization, so starting never throws.
    public func start() async throws {}

    /// One synthesized buffer per clock tick, stamped with the tick's time.
    /// The stream finishes when the tick stream ends, the consumer stops
    /// consuming, or ``stop()`` is called.
    public func audio() -> AsyncStream<CapturedAudio> {
        let frequency = self.frequency
        let sampleRate = self.sampleRate
        let samplesPerBuffer = self.samplesPerBuffer
        let amplitude = self.amplitude
        let tickDuration = CMTime(value: CMTimeValue(samplesPerBuffer), timescale: CMTimeScale(sampleRate))
        return stream.makeStream(
            clock: clock,
            tickInterval: tickDuration,
            inputID: id,
            eventBus: eventBus,
            makeRenderer: {
                ToneSynthesizer(
                    frequency: frequency,
                    sampleRate: sampleRate,
                    samplesPerBuffer: samplesPerBuffer,
                    amplitude: amplitude
                )
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
/// with phase continuity across buffers. Confined to a single synthesis
/// task — never crosses an isolation boundary, so it needs no `Sendable`.
private final class ToneSynthesizer {
    /// The tone frequency in Hertz.
    private let frequency: Double

    /// Samples per second.
    private let sampleRate: Int

    /// Samples per synthesized buffer.
    private let samplesPerBuffer: Int

    /// Peak amplitude of the tone.
    private let amplitude: Float

    /// The running sample position across buffers, keeping the sine phase
    /// continuous. Content state only — PTS always comes from the clock.
    private var samplePosition = 0

    /// The PCM format description shared by every buffer: mono float32 at
    /// the configured sample rate. Nil if creation was refused, in which case
    /// every tick throws ``GeneratorSynthesisFailure/audioFormatDescriptionUnavailable(_:)``.
    private let formatDescription: CMAudioFormatDescription?

    /// The `CMAudioFormatDescriptionCreate` status, kept so a synthesizer
    /// that never got a format description can still say why on every tick.
    private let formatStatus: OSStatus

    /// Creates a synthesizer and its shared format description.
    init(frequency: Double, sampleRate: Int, samplesPerBuffer: Int, amplitude: Float) {
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.samplesPerBuffer = samplesPerBuffer
        self.amplitude = amplitude
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
        let samples = (0..<samplesPerBuffer).map { offset in
            Float(sin(2 * .pi * frequency * Double(samplePosition + offset) / Double(sampleRate))) * amplitude
        }
        samplePosition += samplesPerBuffer

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
