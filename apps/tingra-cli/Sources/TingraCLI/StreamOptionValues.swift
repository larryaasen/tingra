//
//  StreamOptionValues.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser

/// A program resolution parsed from the `WxH` form (`--resolution
/// 1920x1080`, see CLI.md "Compression").
struct Resolution: Equatable, Sendable {
    /// The program width in pixels.
    let width: Int

    /// The program height in pixels.
    let height: Int

    /// Whether both dimensions are even — 4:2:0 delivery requires it
    /// (ARCHITECTURE.md, "Color and pixel format conventions").
    var isEven: Bool {
        width.isMultiple(of: 2) && height.isMultiple(of: 2)
    }
}

extension Resolution: ExpressibleByArgument {
    /// Parses `WxH` with positive integer dimensions, e.g. `1280x720`.
    init?(argument: String) {
        let parts = argument.lowercased().split(separator: "x")
        guard
            parts.count == 2,
            let width = Int(parts[0]),
            let height = Int(parts[1]),
            width > 0,
            height > 0
        else { return nil }
        self.init(width: width, height: height)
    }

    /// The canonical `WxH` form, also what `--help` shows as the default.
    var defaultValueDescription: String { description }
}

extension Resolution: CustomStringConvertible {
    /// The canonical `WxH` form, e.g. `1920x1080`.
    var description: String { "\(width)x\(height)" }
}

/// A bitrate parsed from a bare bits-per-second integer or the `k`/`M`
/// suffix forms (`--video-bitrate 4500k`, see CLI.md "Compression").
struct Bitrate: Equatable, Sendable {
    /// The rate in bits per second.
    let bitsPerSecond: Int
}

extension Bitrate: ExpressibleByArgument {
    /// Parses `4500k`, `6M`, or a bare bits-per-second integer; the value
    /// must be positive.
    init?(argument: String) {
        let multiplier: Int
        var digits = argument
        switch argument.last {
        case "k", "K":
            multiplier = 1000
            digits = String(argument.dropLast())
        case "m", "M":
            multiplier = 1_000_000
            digits = String(argument.dropLast())
        default:
            multiplier = 1
        }
        guard let value = Int(digits), value > 0 else { return nil }
        self.init(bitsPerSecond: value * multiplier)
    }

    /// The compact suffix form, also what `--help` shows as the default.
    var defaultValueDescription: String { description }
}

extension Bitrate: CustomStringConvertible {
    /// The compact form: `k` when the rate is a whole number of kilobits,
    /// otherwise bare bits per second (`4500k`, `160k`, `4500001`).
    var description: String {
        bitsPerSecond.isMultiple(of: 1000) ? "\(bitsPerSecond / 1000)k" : "\(bitsPerSecond)"
    }
}

/// The video codecs `stream` can compress with (`--video-codec`, see
/// CLI.md): H.264 has the broadest destination support; HEVC where the
/// destination accepts it.
enum VideoCodec: String, Sendable, ExpressibleByArgument, CaseIterable {
    case h264
    case hevc
}

/// The audio codecs `stream` can compress with (`--audio-codec`, see
/// CLI.md): AAC only in v1.
enum AudioCodec: String, Sendable, ExpressibleByArgument, CaseIterable {
    case aac
}

/// The video generators `--video-generator` accepts (CLI.md, "Input
/// selection"); values are the generators' stable input identifiers.
enum VideoGeneratorKind: String, Sendable, ExpressibleByArgument, CaseIterable {
    /// SMPTE color bars with burned in timecode.
    case bars

    /// Industry-standard-style alignment pattern, cached after first generation.
    case alignment

    /// PLUGE black-level calibration pattern.
    case pluge

    /// Stricter broadcast-style PLUGE black-level calibration pattern.
    case plugeStrict = "pluge-strict"
}

/// The audio generators `--audio-generator` accepts (CLI.md, "Input
/// selection"); values are the generators' stable input identifiers.
enum AudioGeneratorKind: String, Sendable, ExpressibleByArgument, CaseIterable {
    /// The 440 Hz test tone.
    case tone
}
