//
//  ApplicationAudioBufferTests.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio
import Testing

@testable import TingraApplicationAudio

/// Copying a HAL buffer list out of a callback.
@Suite("ApplicationAudioBuffer")
struct ApplicationAudioBufferTests {
    /// Runs a body over a buffer list built from per-buffer samples, each
    /// buffer carrying the given channel count.
    ///
    /// - Parameters:
    ///   - buffers: Each buffer's samples and channel count.
    ///   - body: What to do with the list.
    /// - Returns: The body's result.
    private func withList<Result>(
        _ buffers: [(samples: [Float], channels: UInt32)],
        _ body: (UnsafeMutableAudioBufferListPointer) -> Result
    ) -> Result {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { list.unsafeMutablePointer.deallocate() }
        var storage: [UnsafeMutablePointer<Float>] = []
        defer { storage.forEach { $0.deallocate() } }
        for (index, buffer) in buffers.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(buffer.samples.count, 1))
            data.initialize(from: buffer.samples, count: buffer.samples.count)
            storage.append(data)
            list[index] = AudioBuffer(
                mNumberChannels: buffer.channels,
                mDataByteSize: UInt32(buffer.samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data))
        }
        return body(list)
    }

    @Test("An interleaved stereo buffer is copied as it is")
    func interleaved() {
        let copy = withList([([0.1, -0.1, 0.2, -0.2], 2)]) {
            ApplicationAudioBuffer(copying: $0, channelCount: 2, sampleRate: 48_000, hostTime: 42)
        }
        #expect(copy?.samples == [0.1, -0.1, 0.2, -0.2])
        #expect(copy?.frameCount == 2)
        #expect(copy?.channelCount == 2)
        #expect(copy?.sampleRate == 48_000)
        #expect(copy?.hostTime == 42)
    }

    @Test("One buffer per channel is interleaved")
    func deinterleaved() {
        let copy = withList([([1, 2, 3], 1), ([-1, -2, -3], 1)]) {
            ApplicationAudioBuffer(copying: $0, channelCount: 2, sampleRate: 44_100, hostTime: 7)
        }
        #expect(copy?.samples == [1, -1, 2, -2, 3, -3])
        #expect(copy?.frameCount == 3)
    }

    @Test("A misshapen list is refused")
    func misshapen() {
        // Channel counts that do not add up.
        let wrongChannels = withList([([1, 2, 3, 4], 2)]) {
            ApplicationAudioBuffer(copying: $0, channelCount: 4, sampleRate: 48_000, hostTime: 0)
        }
        #expect(wrongChannels == nil)
        // Per-channel buffers that disagree on their length.
        let ragged = withList([([1, 2, 3], 1), ([1, 2], 1)]) {
            ApplicationAudioBuffer(copying: $0, channelCount: 2, sampleRate: 48_000, hostTime: 0)
        }
        #expect(ragged == nil)
        // An interleaved buffer with a partial frame.
        let partial = withList([([1, 2, 3], 2)]) {
            ApplicationAudioBuffer(copying: $0, channelCount: 2, sampleRate: 48_000, hostTime: 0)
        }
        #expect(partial == nil)
    }

    @Test("An empty buffer or a zero channel count is refused")
    func empty() {
        let noSamples = withList([([], 2)]) {
            ApplicationAudioBuffer(copying: $0, channelCount: 2, sampleRate: 48_000, hostTime: 0)
        }
        #expect(noSamples == nil)
        let noChannels = withList([([1, 2], 2)]) {
            ApplicationAudioBuffer(copying: $0, channelCount: 0, sampleRate: 48_000, hostTime: 0)
        }
        #expect(noChannels == nil)
    }

    @Test("Equal buffers compare equal and differing ones do not")
    func equality() {
        let one = ApplicationAudioBuffer(samples: [1, 2], channelCount: 2, sampleRate: 48_000, hostTime: 1)
        #expect(one == ApplicationAudioBuffer(samples: [1, 2], channelCount: 2, sampleRate: 48_000, hostTime: 1))
        #expect(one != ApplicationAudioBuffer(samples: [1, 2], channelCount: 2, sampleRate: 48_000, hostTime: 2))
    }
}
