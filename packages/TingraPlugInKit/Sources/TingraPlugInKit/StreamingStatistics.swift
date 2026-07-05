//
//  StreamingStatistics.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A point-in-time snapshot of a ``StreamingService``'s delivery counters,
/// feeding the periodic `stream.stats` events (CLI.md `--stats-interval`;
/// the status sink model in EVENTS.md).
public struct StreamingStatistics: Sendable, Equatable {
    /// Total bytes delivered to the destination since the stream started.
    public let bytesSent: Int

    /// The current delivery rate in bytes per second, as measured by the
    /// service over its most recent window.
    public let bytesPerSecond: Int

    /// The frames per second currently leaving the compressor.
    public let framesPerSecond: Int

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - bytesSent: Total bytes delivered since start.
    ///   - bytesPerSecond: Current delivery rate in bytes per second.
    ///   - framesPerSecond: Frames per second leaving the compressor.
    public init(bytesSent: Int, bytesPerSecond: Int, framesPerSecond: Int) {
        self.bytesSent = bytesSent
        self.bytesPerSecond = bytesPerSecond
        self.framesPerSecond = framesPerSecond
    }
}
