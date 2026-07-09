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

    /// The shared continuation/task plumbing every consumer's audio stream
    /// runs through.
    private let stream = GeneratorStreamCoordinator<CapturedAudio>()

    /// Creates a tone generator. Defaults match the CLI's audio defaults
    /// (440 Hz at 48 kHz, see CLI.md "Compression").
    ///
    /// - Parameters:
    ///   - clock: The clock that paces synthesis and stamps buffers.
    ///   - frequency: The tone frequency in Hertz.
    ///   - sampleRate: Samples per second.
    ///   - samplesPerBuffer: Samples per synthesized buffer.
    public init(
        clock: any EngineClock,
        frequency: Double = 440,
        sampleRate: Int = 48_000,
        samplesPerBuffer: Int = 1024
    ) {
        self.clock = clock
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
            makeRenderer: {
                ToneSynthesizer(
                    frequency: frequency,
                    sampleRate: sampleRate,
                    samplesPerBuffer: samplesPerBuffer,
                    amplitude: amplitude
                )
            },
            render: { synthesizer, tickTime in synthesizer.nextBuffer(at: tickTime) }
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
    /// the configured sample rate. Nil if creation failed; synthesis then
    /// yields nothing.
    private let formatDescription: CMAudioFormatDescription?

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
        CMAudioFormatDescriptionCreate(
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

    /// Synthesizes the next buffer with the given PTS, or nil if a Core
    /// Media allocation failed — a generator problem must never take down
    /// the pipeline, so a failed buffer is simply skipped.
    func nextBuffer(at time: CMTime) -> CapturedAudio? {
        guard let formatDescription else { return nil }
        let samples = (0..<samplesPerBuffer).map { offset in
            Float(sin(2 * .pi * frequency * Double(samplePosition + offset) / Double(sampleRate))) * amplitude
        }
        samplePosition += samplesPerBuffer

        let dataLength = samples.count * MemoryLayout<Float32>.size
        var blockOut: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: dataLength,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataLength,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockOut
            ) == noErr,
            let block = blockOut
        else { return nil }
        let replaceStatus = samples.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard replaceStatus == noErr else { return nil }

        var sampleBufferOut: CMSampleBuffer?
        guard
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: formatDescription,
                sampleCount: samples.count,
                presentationTimeStamp: time,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBufferOut
            ) == noErr,
            let sampleBuffer = sampleBufferOut
        else { return nil }
        return CapturedAudio(sampleBuffer: sampleBuffer)
    }
}
