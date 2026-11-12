//
//  TimeTestSupport.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import TingraPlugInKit

/// A synthetic clock whose `now` a test moves by hand, for the time
/// generators: a change of state takes effect at the master clock's
/// current time, so a test of start, pause, and reset has to say what that
/// time is. Its tick stream yields the scripted times and finishes, like
/// ``SyntheticClock``'s.
final class SettableClock: EngineClock, Sendable {
    /// The current master clock time, as last set.
    private let storage: Mutex<CMTime>

    /// The times the tick stream yields, in order.
    private let tickTimes: [CMTime]

    /// Creates a clock reading `now`, whose tick stream yields `tickTimes`.
    init(now: CMTime = .zero, tickTimes: [CMTime] = []) {
        storage = Mutex(now)
        self.tickTimes = tickTimes
    }

    /// The current master clock time.
    var now: CMTime { storage.withLock { $0 } }

    /// Moves the clock to a master clock time, in whole seconds.
    func set(seconds: Double) {
        storage.withLock { $0 = CMTime(seconds: seconds, preferredTimescale: 600) }
    }

    /// Yields the scripted times, then finishes.
    func tick(every duration: CMTime) -> AsyncStream<CMTime> {
        AsyncStream { continuation in
            for time in tickTimes {
                continuation.yield(time)
            }
            continuation.finish()
        }
    }
}

/// A master clock time in seconds, for brevity in the time generators'
/// tests.
func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// One BGRA pixel of the working format.
struct BGRAPixel: Equatable {
    /// The blue byte.
    let blue: UInt8

    /// The green byte.
    let green: UInt8

    /// The red byte.
    let red: UInt8

    /// The alpha byte.
    let alpha: UInt8
}

/// Reads every visible BGRA pixel of a buffer, top row first, skipping any
/// row padding the pool added.
func bgraPixels(of buffer: CVPixelBuffer) throws -> [BGRAPixel] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var result: [BGRAPixel] = []
    result.reserveCapacity(width * height)
    for y in 0..<height {
        for x in 0..<width {
            let pointer = bytes + y * rowBytes + x * 4
            result.append(BGRAPixel(blue: pointer[0], green: pointer[1], red: pointer[2], alpha: pointer[3]))
        }
    }
    return result
}

/// The smallest rectangle, in buffer coordinates (top row first), holding
/// every pixel that is not fully transparent; nil for a wholly transparent
/// buffer.
func inkBounds(of buffer: CVPixelBuffer) throws -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
    let pixels = try bgraPixels(of: buffer)
    let width = CVPixelBufferGetWidth(buffer)
    var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
    for (index, pixel) in pixels.enumerated() where pixel.alpha != 0 {
        let x = index % width
        let y = index / width
        if let current = bounds {
            bounds = (min(current.minX, x), min(current.minY, y), max(current.maxX, x), max(current.maxY, y))
        } else {
            bounds = (x, y, x, y)
        }
    }
    return bounds
}
