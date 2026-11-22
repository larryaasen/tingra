//
//  InputStreamBufferingTests.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreVideo
import Testing
import TingraPlugInKit

@testable import TingraMediaPlugIns

/// A 2×2 BGRA picture, distinct by identity from every other one made.
///
/// - Returns: The buffer.
/// - Throws: When Core Video will not make one.
private func makePicture() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
    return try #require(buffer)
}

@Suite("Media input stream bounds")
struct InputStreamBufferingTests {
    @Test("a consumer that falls behind a still receives only the newest picture")
    func stalledConsumerGetsTheNewestPicture() async throws {
        let holder = StillFrameHolder(clock: SyntheticClock())
        var frames = holder.frames().makeAsyncIterator()
        let pictures = try (0..<3).map { _ in try makePicture() }
        // Each hold yields at once, so the stream has seen all three before
        // the consumer reads.
        for picture in pictures {
            holder.hold(picture)
        }

        let first = await frames.next()
        #expect(first?.pixelBuffer === pictures.last)
        holder.stop()
        #expect(await frames.next() == nil)
    }

    @Test("a media input's audio streams hold the newest 48 blocks")
    func audioStreamsHoldTheNewestBlocks() {
        guard case .bufferingNewest(let count) = InputStreamBuffering.audio else {
            Issue.record("The audio bound is not a newest-count policy.")
            return
        }
        #expect(count == 48)
    }
}
