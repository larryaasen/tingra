//
//  ToneGeneratorTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("ToneGenerator")
struct ToneGeneratorTests {
    /// The generator defaults the tests script against.
    private static let sampleRate = 48_000
    private static let samplesPerBuffer = 1024

    /// Collects every buffer the generator produces for the scripted ticks.
    private func collectAudio(tickTimes: [CMTime]) async -> [CapturedAudio] {
        await collectAudio(from: ToneGenerator(clock: SyntheticClock(tickTimes: tickTimes)))
    }

    /// Collects every buffer a given generator produces until its clock's
    /// ticks run out.
    private func collectAudio(from generator: ToneGenerator) async -> [CapturedAudio] {
        var buffers: [CapturedAudio] = []
        for await audio in generator.audio() {
            buffers.append(audio)
        }
        return buffers
    }

    /// The peak amplitude the generator's default level stands for: half
    /// amplitude, the tone's level since it was written.
    private static let defaultAmplitude: Float = 0.5

    /// The scripted tick timeline: one tick per buffer duration.
    private static func ticks(count: Int) -> [CMTime] {
        (0..<count).map {
            CMTime(value: CMTimeValue($0 * samplesPerBuffer), timescale: CMTimeScale(sampleRate))
        }
    }

    /// Reads the float32 samples back out of a captured buffer.
    private static func samples(of audio: CapturedAudio) throws -> [Float] {
        let blockBuffer = try #require(CMSampleBufferGetDataBuffer(audio.sampleBuffer))
        var lengthOut = 0
        var pointerOut: UnsafeMutablePointer<CChar>?
        try #require(
            CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &lengthOut,
                dataPointerOut: &pointerOut
            ) == noErr
        )
        let pointer = try #require(pointerOut)
        let count = lengthOut / MemoryLayout<Float32>.size
        return UnsafeRawPointer(pointer).withMemoryRebound(to: Float32.self, capacity: count) {
            Array(UnsafeBufferPointer(start: $0, count: count))
        }
    }

    @Test("one buffer per clock tick, stamped with the tick's master clock time")
    func oneBufferPerTickWithTickPTS() async {
        let ticks = Self.ticks(count: 3)

        let buffers = await collectAudio(tickTimes: ticks)

        #expect(buffers.map(\.presentationTime) == ticks)
    }

    @Test("buffers carry the configured sample count in mono float32 at 48 kHz")
    func buffersCarryConfiguredFormat() async throws {
        let buffers = await collectAudio(tickTimes: Self.ticks(count: 1))

        let sampleBuffer = try #require(buffers.first?.sampleBuffer)
        #expect(CMSampleBufferGetNumSamples(sampleBuffer) == Self.samplesPerBuffer)
        let format = try #require(CMSampleBufferGetFormatDescription(sampleBuffer))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        #expect(asbd.mSampleRate == Float64(Self.sampleRate))
        #expect(asbd.mChannelsPerFrame == 1)
        #expect(asbd.mBitsPerChannel == 32)
        #expect(asbd.mFormatID == kAudioFormatLinearPCM)
    }

    @Test("the tone is a 440 Hz sine at half amplitude, not silence")
    func toneMatchesExpectedSine() async throws {
        let buffers = await collectAudio(tickTimes: Self.ticks(count: 1))

        let samples = try Self.samples(of: try #require(buffers.first))
        let peak = try #require(samples.map(abs).max())
        #expect(abs(peak - 0.5) < 0.01)
        for (offset, sample) in samples.prefix(64).enumerated() {
            let expected = Float(sin(2 * .pi * 440 * Double(offset) / Double(Self.sampleRate))) * 0.5
            #expect(abs(sample - expected) < 0.0001)
        }
    }

    @Test("the sine phase is continuous across consecutive buffers")
    func phaseIsContinuousAcrossBuffers() async throws {
        let buffers = await collectAudio(tickTimes: Self.ticks(count: 2))

        try #require(buffers.count == 2)
        let second = try Self.samples(of: buffers[1])
        let firstSampleOfSecondBuffer = try #require(second.first)
        let expected = Float(sin(2 * .pi * 440 * Double(Self.samplesPerBuffer) / Double(Self.sampleRate))) * 0.5
        #expect(abs(firstSampleOfSecondBuffer - expected) < 0.0001)
    }

    @Test("stop() finishes a live audio stream")
    func stopFinishesStream() async {
        let generator = ToneGenerator(clock: SyntheticClock(staysOpen: true))
        // Create the stream first — AsyncStream registers its continuation
        // at construction, so the stop below reliably finds it.
        let audio = generator.audio()
        let consumer = Task {
            var count = 0
            for await _ in audio {
                count += 1
            }
            return count
        }

        await generator.stop()

        #expect(await consumer.value == 0)
    }

    @Test(
        "the tone declares a frequency and a level, in that order, with the CLI's 440 Hz at half amplitude as defaults")
    func declaresFrequencyAndLevel() {
        let generator = ToneGenerator(clock: SyntheticClock())
        #expect(generator.parameters.map(\.key) == ["frequencyHertz", "levelDecibels"])
        #expect(ToneGenerator.frequencyParameter.defaultValue == 440)
        #expect(ToneGenerator.frequencyParameter.unit == "Hz")
        #expect(ToneGenerator.frequencyParameter.scale == .logarithmic)
        #expect(ToneGenerator.levelParameter.unit == "dB")
        #expect(abs(ToneGenerator.levelParameter.defaultValue - -6.02) < 0.01)
        #expect(generator.currentTuning == .init(frequency: 440, amplitude: Self.defaultAmplitude))
    }

    @Test("setParameters retunes the frequency and level the next buffer is synthesized with")
    func setParametersRetunes() async throws {
        let generator = ToneGenerator(clock: SyntheticClock(tickTimes: Self.ticks(count: 1)))
        await generator.setParameters(["frequencyHertz": .int(1000), "levelDecibels": .double(-20)])

        let buffers = await collectAudio(from: generator)

        let samples = try Self.samples(of: try #require(buffers.first))
        let amplitude = Float(pow(10, -20.0 / 20))
        let peak = try #require(samples.map(abs).max())
        #expect(abs(peak - amplitude) < 0.002)
        for (offset, sample) in samples.prefix(64).enumerated() {
            let expected = Float(sin(2 * .pi * 1000 * Double(offset) / Double(Self.sampleRate))) * amplitude
            #expect(abs(sample - expected) < 0.0001)
        }
    }

    @Test("setParameters clamps values into the declared ranges and restores the defaults for omitted keys")
    func setParametersClampsAndDefaults() async {
        let generator = ToneGenerator(clock: SyntheticClock(), frequency: 880)
        await generator.setParameters(["frequencyHertz": .double(50_000), "levelDecibels": .double(12)])
        #expect(generator.currentTuning == .init(frequency: 20_000, amplitude: 1))

        await generator.setParameters([:])
        #expect(generator.currentTuning == .init(frequency: 440, amplitude: Self.defaultAmplitude))
    }

    @Test("a key the tone does not declare is ignored")
    func setParametersIgnoresForeignKeys() async {
        let generator = ToneGenerator(clock: SyntheticClock())
        await generator.setParameters(["waveform": .string("square"), "frequencyHertz": .double(660)])
        #expect(generator.currentTuning.frequency == 660)
    }

    @Test("the generator carries its stable identifier, name, and kind")
    func identity() {
        let generator = ToneGenerator(clock: SyntheticClock())
        #expect(generator.id == ToneGenerator.inputID)
        #expect(generator.id == InputID(rawValue: "tone"))
        #expect(generator.name == "440 Hz Tone")
        #expect(generator.kind == .generator)
    }
}
