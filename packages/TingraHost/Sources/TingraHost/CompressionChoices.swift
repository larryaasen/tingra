//
//  CompressionChoices.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The rules behind the compression settings an operator chooses from a
/// menu, kept in the host so every front end offers the same choices and
/// derives the same rates (ARCHITECTURE.md, "Compression settings in the
/// app").
///
/// Two rules live here. The **audio bit rates** worth offering for the
/// stereo AAC program mix, with the default the CLI already uses; and the
/// **video bit rate for a codec**, which extends
/// ``StreamConfiguration/recommendedVideoBitsPerSecond(width:height:frameRate:)``
/// — an H.264 figure — to HEVC, so choosing HEVC makes a smaller file
/// rather than the same-size file in a different codec.
///
/// A namespace of pure functions: nothing here is stored, and where a choice
/// persists is the front end's business.
public enum CompressionChoices {
    /// The audio bit rates offered, in bits per second, ascending. Each is a
    /// rate AAC-LC accepts for a stereo mix at 48 kHz; 320k is the highest it
    /// does.
    public static let audioBitRates: [Int] = [96_000, 128_000, 160_000, 192_000, 256_000, 320_000]

    /// The audio bit rate used until the operator chooses one: 160k, the
    /// default of ``StreamConfiguration`` and of `tingra-cli stream`.
    public static let defaultAudioBitsPerSecond = 160_000

    /// The share of an H.264 bit rate HEVC is given. HEVC reaches the same
    /// picture quality at roughly 60 % of H.264's rate, the figure its
    /// platform support is published with ("up to 40 % better compression").
    public static let hevcBitRateShare = 0.6

    /// The offered audio bit rate nearest a stored or requested one, so a
    /// value written by an older build, or by hand, still selects a row of
    /// the menu. A tie goes to the higher rate.
    ///
    /// - Parameter bitsPerSecond: The rate to match.
    /// - Returns: A member of ``audioBitRates``.
    public static func audioBitsPerSecond(nearest bitsPerSecond: Int) -> Int {
        var best = defaultAudioBitsPerSecond
        var bestDistance = Int.max
        for rate in audioBitRates {
            let distance = abs(rate - bitsPerSecond)
            if distance <= bestDistance {
                best = rate
                bestDistance = distance
            }
        }
        return best
    }

    /// The video bit rate to compress a program of the given size and rate
    /// at with the given codec, in bits per second: the pixel-rate rule's
    /// figure for H.264, and ``hevcBitRateShare`` of it for HEVC, rounded to
    /// the nearest 100 kbps and never below 100 kbps.
    ///
    /// - Parameters:
    ///   - width: The program width in pixels.
    ///   - height: The program height in pixels.
    ///   - frameRate: The program frame rate.
    ///   - codec: The video codec.
    /// - Returns: The bit rate for that codec.
    public static func videoBitsPerSecond(
        width: Int,
        height: Int,
        frameRate: Int,
        codec: StreamConfiguration.VideoCodec
    ) -> Int {
        let h264 = StreamConfiguration.recommendedVideoBitsPerSecond(
            width: width, height: height, frameRate: frameRate)
        switch codec {
        case .h264:
            return h264
        case .hevc:
            let step = 100_000.0
            return max(Int(step), Int((Double(h264) * hevcBitRateShare / step).rounded() * step))
        @unknown default:
            // A codec this build does not know has no rule of its own; the
            // H.264 figure is the safe one, never too low for the picture.
            return h264
        }
    }
}
