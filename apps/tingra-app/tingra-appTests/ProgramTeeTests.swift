//
//  ProgramTeeTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Testing
import TingraPlugInKit

@testable import TingraApp

/// The program tee: frames and blocks reach whichever session leaves are
/// attached, detaching finishes a leaf's stream, and attaching over a leaf
/// finishes the one it replaces.
@Suite("ProgramTee")
struct ProgramTeeTests {
    /// A small frame at `time`.
    private func frame(at time: CMTime) throws -> CapturedFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        return CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: time)
    }

    @Test("nothing is attached at first")
    func nothingAttached() {
        let tee = ProgramTee()
        #expect(!tee.isStreamAttached)
        #expect(!tee.isRecordingAttached)
    }

    @Test("a frame reaches every attached video leaf and no detached one")
    func frameReachesAttachedLeaves() async throws {
        let tee = ProgramTee()
        let (streamVideo, streamContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)
        let (_, streamAudio) = AsyncStream.makeStream(of: CapturedAudio.self)
        let (recordVideo, recordContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)
        let (_, recordAudio) = AsyncStream.makeStream(of: CapturedAudio.self)
        tee.attachStream(video: streamContinuation, audio: streamAudio)
        tee.attachRecording(video: recordContinuation, audio: recordAudio)
        #expect(tee.isStreamAttached)
        #expect(tee.isRecordingAttached)

        let time = CMTime(value: 7, timescale: 30)
        tee.yield(try frame(at: time))
        var streamFrames = streamVideo.makeAsyncIterator()
        var recordFrames = recordVideo.makeAsyncIterator()
        #expect(await streamFrames.next()?.presentationTime == time)
        #expect(await recordFrames.next()?.presentationTime == time)

        // Detaching the recording finishes its stream; the stream leaf lives on.
        tee.detachRecording()
        #expect(await recordFrames.next() == nil)
        #expect(!tee.isRecordingAttached)
        tee.yield(try frame(at: CMTime(value: 8, timescale: 30)))
        #expect(await streamFrames.next()?.presentationTime == CMTime(value: 8, timescale: 30))
    }

    @Test("attaching over a leaf finishes the one it replaces")
    func attachingReplacesAndFinishes() async {
        let tee = ProgramTee()
        let (first, firstContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)
        let (_, firstAudio) = AsyncStream.makeStream(of: CapturedAudio.self)
        tee.attachStream(video: firstContinuation, audio: firstAudio)
        let (_, secondContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)
        let (_, secondAudio) = AsyncStream.makeStream(of: CapturedAudio.self)
        tee.attachStream(video: secondContinuation, audio: secondAudio)

        var frames = first.makeAsyncIterator()
        #expect(await frames.next() == nil)
        #expect(tee.isStreamAttached)
    }

    @Test("detaching the stream finishes its leaves and yields go nowhere")
    func detachingStreamFinishes() async throws {
        let tee = ProgramTee()
        let (video, videoContinuation) = AsyncStream.makeStream(of: CapturedFrame.self)
        let (_, audioContinuation) = AsyncStream.makeStream(of: CapturedAudio.self)
        tee.attachStream(video: videoContinuation, audio: audioContinuation)
        tee.detachStream()
        tee.yield(try frame(at: .zero))

        var frames = video.makeAsyncIterator()
        #expect(await frames.next() == nil)
        #expect(!tee.isStreamAttached)
    }
}

/// The frame relay: the latest stored frame is what the monitor reads, and
/// a relay that stops accepting empties and ignores what it is given until
/// it accepts again.
@Suite("ProgramFrameRelay")
struct ProgramFrameRelayTests {
    /// A small frame at `time`.
    private func frame(at time: CMTime) throws -> CapturedFrame {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        return CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: time)
    }

    @Test("empty before the first frame, then the latest stored frame")
    func latestIsTheLastStored() throws {
        let relay = ProgramFrameRelay()
        #expect(relay.latest == nil)
        let first = try frame(at: .zero)
        let second = try frame(at: CMTime(value: 1, timescale: 30))
        relay.store(first)
        relay.store(second)
        #expect(relay.latest === second.pixelBuffer)
    }

    @Test("clearing through the setter empties the relay")
    func settingNilEmpties() throws {
        let relay = ProgramFrameRelay()
        relay.store(try frame(at: .zero))
        relay.latest = nil
        #expect(relay.latest == nil)
    }

    @Test("a relay that stops accepting empties and drops frames until it accepts again")
    func notAcceptingDropsFrames() throws {
        let relay = ProgramFrameRelay()
        relay.store(try frame(at: .zero))
        relay.setAccepting(false)
        #expect(relay.latest == nil)
        relay.store(try frame(at: CMTime(value: 1, timescale: 30)))
        #expect(relay.latest == nil)
        relay.setAccepting(true)
        let accepted = try frame(at: CMTime(value: 2, timescale: 30))
        relay.store(accepted)
        #expect(relay.latest === accepted.pixelBuffer)
    }
}
