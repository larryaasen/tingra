//
//  CaptureInputTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AVFoundation
import CoreMedia
import CoreVideo
import Testing
import TingraPlugInKit

@testable import TingraCapturePlugIns

/// The fixture devices, mirroring the CLI.md examples.
private let fixtureCamera = CaptureDevice(uniqueID: "0x8020000005ac8514", name: "FaceTime HD Camera", kind: .camera)
private let fixtureMicrophone = CaptureDevice(
    uniqueID: "BuiltInMicrophoneDevice",
    name: "MacBook Pro Microphone",
    kind: .microphone
)

@Suite("CameraInput")
struct CameraInputTests {
    @Test("start() throws authorizationDenied when TCC denies camera access")
    func startThrowsWhenAuthorizationDenied() async {
        let input = CameraInput(device: fixtureCamera, requestAuthorization: { false })

        await #expect(throws: CaptureInputError.authorizationDenied(.camera, input.id)) {
            try await input.start()
        }
    }

    @Test("the input carries the device's identifier, name, and kind")
    func identity() {
        let input = CameraInput(device: fixtureCamera, requestAuthorization: { false })
        #expect(input.id == InputID(rawValue: "0x8020000005ac8514"))
        #expect(input.name == "FaceTime HD Camera")
        #expect(input.kind == .camera)
    }

    @Test("stop() before start is safe and finishes an attached stream")
    func stopBeforeStartIsSafe() async {
        let input = CameraInput(device: fixtureCamera, requestAuthorization: { false })
        let frames = input.frames()
        let consumer = Task {
            var count = 0
            for await _ in frames {
                count += 1
            }
            return count
        }

        await input.stop()
        await input.stop()

        #expect(await consumer.value == 0)
    }
}

@Suite("MicrophoneInput")
struct MicrophoneInputTests {
    @Test("start() throws authorizationDenied when TCC denies microphone access")
    func startThrowsWhenAuthorizationDenied() async {
        let input = MicrophoneInput(device: fixtureMicrophone, requestAuthorization: { false })

        await #expect(throws: CaptureInputError.authorizationDenied(.microphone, input.id)) {
            try await input.start()
        }
    }

    @Test("the input carries the device's identifier, name, and kind")
    func identity() {
        let input = MicrophoneInput(device: fixtureMicrophone, requestAuthorization: { false })
        #expect(input.id == InputID(rawValue: "BuiltInMicrophoneDevice"))
        #expect(input.name == "MacBook Pro Microphone")
        #expect(input.kind == .microphone)
    }

    @Test("a tapped PCM buffer converts with its AVAudioTime host time as the PTS")
    func conversionKeepsHostTimePTS() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let hostTime: UInt64 = 123_456_789

        let audio = try #require(
            MicrophoneInput.capturedAudio(from: buffer, at: AVAudioTime(hostTime: hostTime))
        )

        #expect(audio.presentationTime == CMClockMakeHostTimeFromSystemUnits(hostTime))
        #expect(CMSampleBufferGetNumSamples(audio.sampleBuffer) == 256)
    }

    @Test("a tap time with no host time yields no buffer — PTS is never synthesized")
    func conversionSkipsBuffersWithoutHostTime() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        // Sample-time-only, per CLOCK.md: a synthetic sample-count position
        // must never become a PTS.
        let sampleTimeOnly = AVAudioTime(sampleTime: 4800, atRate: 48_000)

        #expect(MicrophoneInput.capturedAudio(from: buffer, at: sampleTimeOnly) == nil)
    }
}

@Suite("FrameNormalization")
struct FrameNormalizationTests {
    /// Creates a bare test pixel buffer with no color attachments.
    private func makeBuffer() throws -> CVPixelBuffer {
        var bufferOut: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &bufferOut)
                == kCVReturnSuccess
        )
        return try #require(bufferOut)
    }

    @Test("an untagged buffer gains the full BT.709 attachment set")
    func untaggedBufferGetsTagged() throws {
        let buffer = try makeBuffer()

        FrameNormalization.tagBT709IfUntagged(buffer)

        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil)
        let matrix = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        #expect(primaries as? String == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(transfer as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        #expect(matrix as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    @Test("existing color attachments are preserved — the framework knows the true colorimetry")
    func existingTagsArePreserved() throws {
        let buffer = try makeBuffer()
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_P3_D65,
            .shouldPropagate
        )

        FrameNormalization.tagBT709IfUntagged(buffer)

        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)
        #expect(primaries as? String == kCVImageBufferColorPrimaries_P3_D65 as String)
        // The missing attachments are still filled in.
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil)
        #expect(transfer as? String == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    }
}

@Suite("CaptureInputError")
struct CaptureInputErrorTests {
    @Test("each error maps to its stable error identifier")
    func identifierMapping() {
        let id = InputID(rawValue: "0x1")
        #expect(CaptureInputError.authorizationDenied(.camera, id).identifier == .authorizationDenied)
        #expect(CaptureInputError.deviceUnavailable(id).identifier == .inputNotFound)
        #expect(CaptureInputError.configurationRejected(id, "step").identifier == .pipelineError)
    }

    @Test("descriptions name the input, the cause, and the fix")
    func descriptionsAreDeveloperFacing() {
        let id = InputID(rawValue: "0x1")
        let denied = String(describing: CaptureInputError.authorizationDenied(.camera, id))
        #expect(denied.contains("0x1"))
        #expect(denied.contains("System Settings"))
        let unavailable = String(describing: CaptureInputError.deviceUnavailable(id))
        #expect(unavailable.contains("no longer connected"))
        let rejected = String(describing: CaptureInputError.configurationRejected(id, "the session said no"))
        #expect(rejected.contains("the session said no"))
    }
}
