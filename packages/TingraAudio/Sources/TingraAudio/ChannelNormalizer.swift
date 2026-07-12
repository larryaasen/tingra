//
//  ChannelNormalizer.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import CoreMedia
import Synchronization
import TingraPlugInKit

/// Converts one channel strip's incoming audio into the mix's canonical
/// sample format: float32, deinterleaved, at the mix sample rate, keeping the
/// source's channel count (the mix loop spreads mono to both program
/// channels; see ``AudioMixer``). Conversion happens here, once, at channel
/// intake — the audio mirror of the video rule that conversion happens once,
/// at input normalization (ARCHITECTURE.md).
///
/// Not `Sendable` by design: it holds an `AVAudioConverter` whose resampler
/// carries filter state across buffers, so each channel's fill task owns one
/// normalizer, task-confined — the same confinement pattern as the
/// compositor's `ShotRenderer`.
struct ChannelNormalizer {
    /// The canonical sample rate normalized samples leave at.
    let sampleRate: Double

    /// The persistent converter for the current source format, so sample
    /// rate conversion keeps its filter state across buffers. Rebuilt when
    /// the source format changes (a device format change mid-stream).
    private var converter: AVAudioConverter?

    /// The source format ``converter`` was built for.
    private var converterSourceFormat: AVAudioFormat?

    /// Creates a normalizer targeting the given mix sample rate.
    ///
    /// - Parameter sampleRate: The canonical sample rate in hertz.
    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Normalizes one captured buffer into canonical samples, channel-major
    /// (one `[Float]` per source channel, equal lengths). Returns nil for a
    /// non-PCM or empty buffer, or when Core Media / the converter rejects
    /// it — that buffer is skipped, never fatal (the channel simply
    /// contributes silence for its span).
    ///
    /// - Parameter audio: The captured audio to normalize.
    /// - Returns: The normalized samples, or nil.
    mutating func normalize(_ audio: CapturedAudio) -> [[Float]]? {
        guard
            let description = CMSampleBufferGetFormatDescription(audio.sampleBuffer),
            CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM
        else { return nil }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(audio.sampleBuffer))
        guard
            frames > 0,
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames)
        else { return nil }
        source.frameLength = frames
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                audio.sampleBuffer,
                at: 0,
                frameCount: Int32(frames),
                into: source.mutableAudioBufferList
            ) == noErr
        else { return nil }

        // Already canonical: no conversion, just copy the samples out.
        if sourceFormat.commonFormat == .pcmFormatFloat32, !sourceFormat.isInterleaved,
            sourceFormat.sampleRate == sampleRate
        {
            return samples(from: source)
        }
        return converted(source, from: sourceFormat).flatMap(samples(from:))
    }

    /// Runs the source buffer through the persistent converter, building (or
    /// rebuilding) the converter when the source format is new. Returns nil
    /// when the converter cannot be built or reports an error.
    private mutating func converted(
        _ source: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if converter == nil || converterSourceFormat != sourceFormat {
            guard
                let target = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate, channels: sourceFormat.channelCount),
                let built = AVAudioConverter(from: sourceFormat, to: target)
            else { return nil }
            converter = built
            converterSourceFormat = sourceFormat
        }
        guard let converter else { return nil }

        let ratio = sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        // Feed the one source buffer, then report the input dry: the
        // converter returns whatever it can produce now and keeps its
        // resampler state for the next buffer. The input block is called
        // synchronously within `convert`, but its `@Sendable` annotation
        // wants a data-race-free flag — an atomic exchange provides it.
        let delivered = Atomic<Bool>(false)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !delivered.exchange(true, ordering: .relaxed) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return source
        }
        guard status != .error, conversionError == nil else { return nil }
        return output
    }

    /// Copies a canonical (float32, deinterleaved) buffer's samples out,
    /// channel-major. Returns nil when the buffer carries no float data.
    private func samples(from buffer: AVAudioPCMBuffer) -> [[Float]]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: channelData[channel], count: frames))
        }
    }
}
