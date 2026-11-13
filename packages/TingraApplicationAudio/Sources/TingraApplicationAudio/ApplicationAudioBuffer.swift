//
//  ApplicationAudioBuffer.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio

/// One callback's worth of an application's audio, copied out of the HAL's
/// buffer and stamped with the host time Core Audio gave it.
///
/// The HAL reuses its buffers between callbacks, so a tap never hands one
/// on: it copies the samples into this value first, which is then owned
/// outright and safe to send anywhere.
public struct ApplicationAudioBuffer: Sendable, Equatable {
    /// The samples, interleaved by frame: `frameCount × channelCount` 32-bit
    /// floats.
    public let samples: [Float]

    /// The number of channels per frame.
    public let channelCount: Int

    /// The sample rate in hertz.
    public let sampleRate: Double

    /// The host time (`mach_absolute_time` units) of the buffer's first
    /// frame — the callback's input timestamp, `AudioTimeStamp.mHostTime`.
    public let hostTime: UInt64

    /// The number of frames.
    public var frameCount: Int { channelCount > 0 ? samples.count / channelCount : 0 }

    /// Creates a buffer from samples already interleaved.
    ///
    /// - Parameters:
    ///   - samples: The interleaved samples.
    ///   - channelCount: Channels per frame.
    ///   - sampleRate: The sample rate in hertz.
    ///   - hostTime: The host time of the first frame.
    public init(samples: [Float], channelCount: Int, sampleRate: Double, hostTime: UInt64) {
        self.samples = samples
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.hostTime = hostTime
    }

    /// Copies a HAL buffer list into an interleaved buffer.
    ///
    /// Takes either layout the HAL may hand over: one interleaved buffer
    /// carrying every channel, or one buffer per channel. Any other shape —
    /// buffers whose channel counts do not add up, or that disagree on their
    /// frame count — is refused rather than guessed at.
    ///
    /// - Parameters:
    ///   - list: The callback's input buffer list.
    ///   - channelCount: The tap's channel count.
    ///   - sampleRate: The tap's sample rate.
    ///   - hostTime: The callback's input host time.
    /// - Returns: The copy, or nil for an empty or misshapen list.
    public init?(
        copying list: UnsafeMutableAudioBufferListPointer,
        channelCount: Int,
        sampleRate: Double,
        hostTime: UInt64
    ) {
        guard channelCount > 0, !list.isEmpty else { return nil }
        let floatSize = MemoryLayout<Float>.size
        if list.count == 1, Int(list[0].mNumberChannels) == channelCount {
            let buffer = list[0]
            let count = Int(buffer.mDataByteSize) / floatSize
            guard count > 0, count % channelCount == 0, let data = buffer.mData else { return nil }
            let floats = data.assumingMemoryBound(to: Float.self)
            self.init(
                samples: Array(UnsafeBufferPointer(start: floats, count: count)),
                channelCount: channelCount, sampleRate: sampleRate, hostTime: hostTime)
            return
        }
        guard list.count == channelCount, list.allSatisfy({ $0.mNumberChannels == 1 }) else { return nil }
        let frames = Int(list[0].mDataByteSize) / floatSize
        guard frames > 0, list.allSatisfy({ Int($0.mDataByteSize) / floatSize == frames }) else { return nil }
        var samples = [Float](repeating: 0, count: frames * channelCount)
        for (channel, buffer) in list.enumerated() {
            guard let data = buffer.mData else { return nil }
            let floats = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                samples[frame * channelCount + channel] = floats[frame]
            }
        }
        self.init(samples: samples, channelCount: channelCount, sampleRate: sampleRate, hostTime: hostTime)
    }
}
