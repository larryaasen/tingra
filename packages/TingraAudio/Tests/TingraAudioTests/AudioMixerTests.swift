//
//  AudioMixerTests.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import CoreMedia
import Testing
import TingraEventBus
import TingraPlugInKit

@testable import TingraAudio

/// A deterministic clock for tests, per CLOCK.md's substitution rule: the
/// tick stream yields exactly the scripted times, then finishes.
private struct SyntheticClock: EngineClock {
    /// The times the tick stream yields, in order.
    let tickTimes: [CMTime]

    /// Yields the scripted times regardless of the requested duration — the
    /// test decides the timeline.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { continuation in
            for time in tickTimes {
                continuation.yield(time)
            }
            continuation.finish()
        }
    }

    var now: CMTime { tickTimes.first ?? .zero }
}

/// A trivial audio input that yields scripted PCM buffers then finishes,
/// standing in for a microphone under a synthetic clock — no hardware, no
/// TCC (CLAUDE.md, Testing).
private final class FakeAudioInput: Input, Sendable {
    let id: InputID
    let name: String
    let kind: InputKind = .microphone

    /// The buffers `audio()` yields, in order.
    private let buffers: [CapturedAudio]

    init(id: String, buffers: [CapturedAudio]) {
        self.id = InputID(rawValue: id)
        self.name = id
        self.buffers = buffers
    }

    func start() async throws {}
    func stop() async {}

    func audio() -> AsyncStream<CapturedAudio> {
        let buffers = self.buffers
        return AsyncStream { continuation in
            for buffer in buffers {
                continuation.yield(buffer)
            }
            continuation.finish()
        }
    }
}

/// Builds one captured PCM buffer from channel-major float samples in the
/// platform's standard (float32, deinterleaved) format at the given rate.
private func makeAudio(channels: [[Float]], sampleRate: Double, time: CMTime = .zero) -> CapturedAudio? {
    guard
        let firstChannel = channels.first,
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(firstChannel.count)),
        let channelData = buffer.floatChannelData
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(firstChannel.count)
    for channel in channels.indices {
        channels[channel].withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channelData[channel].update(from: base, count: source.count)
        }
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
            sampleCount: CMItemCount(buffer.frameLength),
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

/// Reads a mixed block's samples back out, channel-major, via the intake
/// normalizer's fast path (the block is already canonical at the mix rate).
private func samples(of audio: CapturedAudio, sampleRate: Double) -> [[Float]]? {
    var normalizer = ChannelNormalizer(sampleRate: sampleRate)
    return normalizer.normalize(audio)
}

/// Drains up to `limit` mixed blocks from the stream.
private func collect(_ stream: AsyncStream<CapturedAudio>, limit: Int) async -> [CapturedAudio] {
    var blocks: [CapturedAudio] = []
    for await block in stream {
        blocks.append(block)
        if blocks.count == limit { break }
    }
    return blocks
}

/// Drains up to `limit` meter blocks from the stream.
private func collectMeters(_ stream: AsyncStream<MeterBlock>, limit: Int) async -> [MeterBlock] {
    var blocks: [MeterBlock] = []
    for await block in stream {
        blocks.append(block)
        if blocks.count == limit { break }
    }
    return blocks
}

/// Waits long enough for the mixer's fill tasks to drain scripted inputs
/// into their channel queues (the pattern the compositor tests use).
private func letFillTasksDrain() async {
    try? await Task.sleep(nanoseconds: 20_000_000)
}

@Suite("AudioMixer")
struct AudioMixerTests {
    /// The mix format the tests run at: the production rate with the
    /// production block size.
    private let format = MixFormat()

    /// Contiguous tick times at the mix block cadence.
    private func ticks(_ count: Int) -> [CMTime] {
        (0..<count).map {
            CMTime(
                value: CMTimeValue($0 * format.blockFrames),
                timescale: CMTimeScale(format.sampleRate)
            )
        }
    }

    /// A mixer over a synthetic clock scripted with the given ticks.
    private func makeMixer(tickTimes: [CMTime], format: MixFormat? = nil) -> AudioMixer {
        AudioMixer(
            clock: SyntheticClock(tickTimes: tickTimes),
            format: format ?? self.format,
            eventBus: EventBus()
        )
    }

    @Test("one mixed block per tick, stamped with the tick's time — silence before any strip delivers")
    func silenceBlocksFromFirstTick() async throws {
        let tickTimes = ticks(2)
        let mixer = makeMixer(tickTimes: tickTimes)

        let program = mixer.programAudio()
        mixer.start()
        let blocks = await collect(program, limit: 2)

        #expect(blocks.map(\.presentationTime) == tickTimes)
        for block in blocks {
            let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
            #expect(channels.count == 2)
            #expect(channels.allSatisfy { $0.count == format.blockFrames })
            #expect(channels.allSatisfy { $0.allSatisfy { $0 == 0 } })
        }
    }

    @Test("a mono strip's samples reach both program channels, scaled by its level")
    func monoStripScaledByLevel() async throws {
        let source = [Float](repeating: 0.5, count: format.blockFrames)
        let audio = try #require(makeAudio(channels: [source], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]), level: 0.5)])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(abs((channels[0].first ?? 0) - 0.25) < 0.0001)
        #expect(channels[0] == channels[1])
    }

    @Test("a stereo strip maps its left and right channels through the mix")
    func stereoStripMapsLeftAndRight() async throws {
        let left = [Float](repeating: 0.2, count: format.blockFrames)
        let right = [Float](repeating: 0.4, count: format.blockFrames)
        let audio = try #require(makeAudio(channels: [left, right], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "stereo", buffers: [audio]))])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(abs((channels[0].first ?? 0) - 0.2) < 0.0001)
        #expect(abs((channels[1].first ?? 0) - 0.4) < 0.0001)
    }

    @Test("two strips sum into the program mix")
    func twoStripsSum() async throws {
        let first = try #require(
            makeAudio(channels: [[Float](repeating: 0.25, count: format.blockFrames)], sampleRate: format.sampleRate))
        let second = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([
            ChannelStrip(input: FakeAudioInput(id: "a", buffers: [first])),
            ChannelStrip(input: FakeAudioInput(id: "b", buffers: [second])),
        ])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(abs((channels[0].first ?? 0) - 0.75) < 0.0001)
    }

    @Test("a muted strip contributes silence regardless of its level")
    func mutedStripContributesSilence() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([
            ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]), level: 1, isMuted: true)
        ])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(channels.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test("setLevel and setMuted apply to the strips of the mix")
    func settersApplyToStrips() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let input = FakeAudioInput(id: "mic", buffers: [audio])
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: input, level: 1, isMuted: true)])
        mixer.setMuted(false, forInput: input.id)
        mixer.setLevel(0.5, forInput: input.id)
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(abs((channels[0].first ?? 0) - 0.25) < 0.0001)
    }

    @Test("a negative level is treated as silent, never inverted")
    func negativeLevelIsSilent() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]), level: -1)])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(channels.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test("a mono strip panned hard left reaches only the left program channel, at the law's √2 gain")
    func monoStripPannedHardLeft() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]), pan: -1)])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(abs((channels[0].first ?? 0) - 0.5 * Float(2.0.squareRoot())) < 0.0001)
        #expect(channels[1].allSatisfy { $0 == 0 })
    }

    @Test("a mono strip panned hard right reaches only the right program channel, scaled by its level")
    func monoStripPannedHardRight() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([
            ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]), level: 0.5, pan: 1)
        ])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(channels[0].allSatisfy { $0 == 0 })
        #expect(abs((channels[1].first ?? 0) - 0.25 * Float(2.0.squareRoot())) < 0.0001)
    }

    @Test("a centered pan mixes exactly as the pre-pan spread — unity into both program channels")
    func centeredPanPreservesTheSpread() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]), pan: 0)])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(channels[0].first == 0.5)
        #expect(channels[0] == channels[1])
    }

    @Test("a stereo strip's pan is a balance: hard right keeps only the source's right channel, never folds the left")
    func stereoStripPannedHardRightIsABalance() async throws {
        let left = [Float](repeating: 0.2, count: format.blockFrames)
        let right = [Float](repeating: 0.4, count: format.blockFrames)
        let audio = try #require(makeAudio(channels: [left, right], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "stereo", buffers: [audio]), pan: 1)])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(channels[0].allSatisfy { $0 == 0 })
        #expect(abs((channels[1].first ?? 0) - 0.4 * Float(2.0.squareRoot())) < 0.0001)
    }

    @Test("setPan applies to the strips of the mix")
    func setPanAppliesToStrips() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let input = FakeAudioInput(id: "mic", buffers: [audio])
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: input)])
        mixer.setPan(-1, forInput: input.id)
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(abs((channels[0].first ?? 0) - 0.5 * Float(2.0.squareRoot())) < 0.0001)
        #expect(channels[1].allSatisfy { $0 == 0 })
    }

    @Test("a pan beyond the range is clamped to hard, never over-rotated")
    func panBeyondRangeIsClamped() {
        let hardLeft = AudioMixer.panGains(-5)
        let hardRight = AudioMixer.panGains(5)
        #expect(abs(hardLeft.left - Float(2.0.squareRoot())) < 0.0001)
        #expect(hardLeft.right == 0)
        #expect(hardRight.left == 0)
        #expect(abs(hardRight.right - Float(2.0.squareRoot())) < 0.0001)
    }

    @Test("a strip at another sample rate is converted to the mix rate at intake")
    func sampleRateConversionAtIntake() async throws {
        // Two blocks' worth of a constant signal at half the mix rate: the
        // second block sits past the resampler's startup transient.
        let source = [Float](repeating: 0.5, count: format.blockFrames * 2)
        let audio = try #require(makeAudio(channels: [source], sampleRate: format.sampleRate / 2))
        let mixer = makeMixer(tickTimes: ticks(2))
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]))])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let blocks = await collect(program, limit: 2)

        let second = try #require(blocks.last)
        let channels = try #require(samples(of: second, sampleRate: format.sampleRate))
        let middle = channels[0][format.blockFrames / 2]
        #expect(abs(middle - 0.5) < 0.05)
    }

    @Test("a channel's queue is capped: the oldest samples drop, the newest mix")
    func queueCapDropsOldestSamples() async throws {
        // A tiny mix format so the one-second cap is observable: capacity
        // 1000 samples, blocks of 100.
        let tiny = MixFormat(sampleRate: 1000, blockFrames: 100)
        let source = (0..<1200).map { Float($0) / 2400 }
        let audio = try #require(makeAudio(channels: [source], sampleRate: tiny.sampleRate))
        let tickTimes = [CMTime(value: 0, timescale: CMTimeScale(tiny.sampleRate))]
        let mixer = makeMixer(tickTimes: tickTimes, format: tiny)
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]))])
        await letFillTasksDrain()

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        // 1200 queued into a 1000 cap: samples 0..<200 dropped, so the first
        // block starts at source sample 200.
        let channels = try #require(samples(of: block, sampleRate: tiny.sampleRate))
        #expect(abs(channels[0][0] - source[200]) < 0.0001)
        #expect(abs(channels[0][99] - source[299]) < 0.0001)
    }

    @Test("a removed strip no longer reaches the mix")
    func removedStripLeavesTheMix() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: FakeAudioInput(id: "mic", buffers: [audio]))])
        await letFillTasksDrain()
        mixer.setChannelStrips([])

        let program = mixer.programAudio()
        mixer.start()
        let block = try #require(await collect(program, limit: 1).first)

        let channels = try #require(samples(of: block, sampleRate: format.sampleRate))
        #expect(channels.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test("stop finishes the program-audio stream")
    func stopFinishesProgramStream() async {
        let mixer = makeMixer(tickTimes: ticks(1))
        let program = mixer.programAudio()
        mixer.start()
        _ = await collect(program, limit: 1)

        mixer.stop()
        // The finished stream ends this loop; reaching the expectation is
        // the assertion.
        for await _ in program {}
        #expect(Bool(true))
    }

    @Test("the mixed block factory returns nil for empty or mismatched channels")
    func blockFactoryRejectsBadInput() {
        #expect(AudioMixer.capturedAudio(left: [], right: [], at: .zero, sampleRate: 48_000) == nil)
        #expect(AudioMixer.capturedAudio(left: [0, 0], right: [0], at: .zero, sampleRate: 48_000) == nil)
    }

    @Test("a constant signal meters to its known peak and RMS")
    func constantSignalMetersKnownReading() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let input = FakeAudioInput(id: "mic", buffers: [audio])
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: input)])
        await letFillTasksDrain()

        let meters = mixer.meterReadings()
        mixer.start()
        let block = try #require(await collectMeters(meters, limit: 1).first)

        let reading = try #require(block.strips[input.id])
        #expect(abs(reading.peak - 0.5) < 0.0001)
        #expect(abs(reading.rms - 0.5) < 0.0001)
    }

    @Test("peak and RMS are measured distinctly — a half-silent block's RMS sits below its peak")
    func peakAndRMSMeasuredDistinctly() async throws {
        // Half the block at 0.8, half at silence: peak 0.8, RMS 0.8/√2.
        let half = format.blockFrames / 2
        let source = [Float](repeating: 0.8, count: half) + [Float](repeating: 0, count: format.blockFrames - half)
        let audio = try #require(makeAudio(channels: [source], sampleRate: format.sampleRate))
        let input = FakeAudioInput(id: "mic", buffers: [audio])
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: input)])
        await letFillTasksDrain()

        let meters = mixer.meterReadings()
        mixer.start()
        let block = try #require(await collectMeters(meters, limit: 1).first)

        let reading = try #require(block.strips[input.id])
        #expect(abs(reading.peak - 0.8) < 0.0001)
        #expect(abs(reading.rms - 0.8 / Float(2.0.squareRoot())) < 0.0001)
    }

    @Test("metering is pre-fader: a muted strip at zero level still meters its delivered signal")
    func mutedStripStillMetersItsSignal() async throws {
        let audio = try #require(
            makeAudio(channels: [[Float](repeating: 0.5, count: format.blockFrames)], sampleRate: format.sampleRate))
        let input = FakeAudioInput(id: "mic", buffers: [audio])
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: input, level: 0, isMuted: true)])
        await letFillTasksDrain()

        let meters = mixer.meterReadings()
        let program = mixer.programAudio()
        mixer.start()
        let meterBlock = try #require(await collectMeters(meters, limit: 1).first)
        let mixedBlock = try #require(await collect(program, limit: 1).first)

        // The meter reads the intake; the program mix stays silent.
        let reading = try #require(meterBlock.strips[input.id])
        #expect(abs(reading.peak - 0.5) < 0.0001)
        let channels = try #require(samples(of: mixedBlock, sampleRate: format.sampleRate))
        #expect(channels.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    @Test("a stereo strip meters its hotter channel")
    func stereoStripMetersHotterChannel() async throws {
        let left = [Float](repeating: 0.2, count: format.blockFrames)
        let right = [Float](repeating: 0.4, count: format.blockFrames)
        let audio = try #require(makeAudio(channels: [left, right], sampleRate: format.sampleRate))
        let input = FakeAudioInput(id: "stereo", buffers: [audio])
        let mixer = makeMixer(tickTimes: ticks(1))
        mixer.setChannelStrips([ChannelStrip(input: input)])
        await letFillTasksDrain()

        let meters = mixer.meterReadings()
        mixer.start()
        let block = try #require(await collectMeters(meters, limit: 1).first)

        let reading = try #require(block.strips[input.id])
        #expect(abs(reading.peak - 0.4) < 0.0001)
        #expect(abs(reading.rms - 0.4) < 0.0001)
    }

    @Test("a strip with nothing queued meters at the floor — one block per tick, stamped with the tick's time")
    func silentStripMetersAtTheFloor() async throws {
        let tickTimes = ticks(2)
        let input = FakeAudioInput(id: "mic", buffers: [])
        let mixer = makeMixer(tickTimes: tickTimes)
        mixer.setChannelStrips([ChannelStrip(input: input)])
        await letFillTasksDrain()

        let meters = mixer.meterReadings()
        mixer.start()
        let blocks = await collectMeters(meters, limit: 2)

        #expect(blocks.map(\.time) == tickTimes)
        for block in blocks {
            #expect(block.strips[input.id] == .floor)
        }
    }

    @Test("stop finishes the meter stream")
    func stopFinishesMeterStream() async {
        let mixer = makeMixer(tickTimes: ticks(1))
        let meters = mixer.meterReadings()
        mixer.start()
        _ = await collectMeters(meters, limit: 1)

        mixer.stop()
        // The finished stream ends this loop; reaching the expectation is
        // the assertion.
        for await _ in meters {}
        #expect(Bool(true))
    }
}
