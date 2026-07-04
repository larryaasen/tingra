//
//  MicrophoneInput.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Synchronization
import TingraPlugInKit

/// A microphone behind the `Input` seam: an `AVAudioEngine` input tap
/// delivering PCM buffers whose PTS is the actual host time of capture from
/// `AVAudioTime.hostTime` — never a synthetic sample-count position
/// (CLOCK.md, Timestamp rules). Nothing downstream imports AVFoundation or
/// Core Audio.
///
/// The engine machinery is a hardware path: it gets this seam, not unit
/// tests; the buffer conversion and the authorization-denied path are the
/// testable parts (CLAUDE.md, Testing).
final class MicrophoneInput: Input, Sendable {
    /// The discovered device this input captures from.
    private let device: CaptureDevice

    /// Requests microphone authorization, returning whether access is
    /// granted. Production asks TCC via `AVCaptureDevice.requestAccess`;
    /// tests inject a fixed answer.
    private let requestAuthorization: @Sendable () async -> Bool

    /// The stop signal for the running engine task and the single active
    /// audio continuation. One holder at a time, per the frame ownership
    /// rule (ARCHITECTURE.md): a new `audio()` call finishes and replaces
    /// the previous stream.
    private let state = Mutex<CaptureState>(CaptureState())

    /// The mutable capture state behind the mutex — `Sendable` handles
    /// only; the engine itself stays inside its task.
    private struct CaptureState {
        /// Finishing this ends the engine task, while started.
        var stopSignal: AsyncStream<Never>.Continuation?

        /// The single active audio continuation, while a consumer is
        /// attached.
        var continuation: AsyncStream<CapturedAudio>.Continuation?
    }

    /// Creates a microphone input over a discovered device.
    ///
    /// - Parameters:
    ///   - device: The discovered microphone.
    ///   - requestAuthorization: The authorization seam; defaults to the
    ///     real TCC request.
    init(
        device: CaptureDevice,
        requestAuthorization: @escaping @Sendable () async -> Bool = MicrophoneInput.requestMicrophoneAccess
    ) {
        self.device = device
        self.requestAuthorization = requestAuthorization
    }

    /// The stable identifier — the device's unique ID, verbatim, so
    /// `devices --json` output works as a selector across launches.
    var id: InputID { InputID(rawValue: device.uniqueID) }

    /// The user-facing device name.
    var name: String { device.name }

    /// A microphone.
    var kind: InputKind { device.kind }

    /// Requests authorization, points the engine's input at this device,
    /// and starts the tap.
    ///
    /// Throws ``CaptureInputError/authorizationDenied(_:_:)`` when TCC
    /// denies microphone access, ``CaptureInputError/deviceUnavailable(_:)``
    /// when the device's Core Audio identity cannot be resolved (it
    /// disconnected since discovery), and
    /// ``CaptureInputError/configurationRejected(_:_:)`` when the engine
    /// rejects the device or fails to start. Device disconnection after a
    /// successful start is a normal event, never an error.
    func start() async throws {
        guard await requestAuthorization() else {
            throw CaptureInputError.authorizationDenied(.microphone, id)
        }

        let (stopSignal, stopContinuation) = AsyncStream.makeStream(of: Never.self)
        let device = self.device
        let inputID = id
        let deliver: @Sendable (CapturedAudio) -> Void = { [weak self] audio in
            self?.state.withLock { $0.continuation }?.yield(audio)
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            Task {
                let engine: AVAudioEngine
                do {
                    engine = try Self.makeRunningEngine(for: device, id: inputID, deliver: deliver)
                } catch {
                    ready.resume(throwing: error)
                    return
                }
                ready.resume()
                // Park until stop() finishes the signal (or the task is
                // cancelled); the engine stays alive and task-confined for
                // the duration.
                for await _ in stopSignal {}
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        state.withLock { $0.stopSignal = stopContinuation }
    }

    /// Builds, configures, and starts the audio engine for a device.
    /// Called from (and its result confined to) the engine task.
    private static func makeRunningEngine(
        for device: CaptureDevice,
        id: InputID,
        deliver: @escaping @Sendable (CapturedAudio) -> Void
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        guard
            let deviceID = audioDeviceID(forUID: device.uniqueID),
            let audioUnit = engine.inputNode.audioUnit
        else {
            throw CaptureInputError.deviceUnavailable(id)
        }
        var selectedDevice = deviceID
        let selectionStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard selectionStatus == noErr else {
            throw CaptureInputError.configurationRejected(
                id,
                "the audio engine did not accept the device (Core Audio status \(selectionStatus))"
            )
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            guard let audio = capturedAudio(from: buffer, at: when) else { return }
            deliver(audio)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw CaptureInputError.configurationRejected(
                id,
                "the audio engine did not start: \(error.localizedDescription)"
            )
        }
        return engine
    }

    /// The stream of captured audio. One consumer at a time: a new call
    /// finishes the previous stream and takes over, per the frame
    /// ownership rule.
    func audio() -> AsyncStream<CapturedAudio> {
        AsyncStream { continuation in
            let previous = state.withLock { state in
                let previous = state.continuation
                state.continuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    /// Ends the engine task (which removes the tap and stops the engine)
    /// and finishes the audio stream. Safe to call more than once.
    func stop() async {
        let (stopSignal, continuation) = state.withLock { state in
            let pair = (state.stopSignal, state.continuation)
            state.stopSignal = nil
            state.continuation = nil
            return pair
        }
        stopSignal?.finish()
        continuation?.finish()
    }

    /// Wraps one tapped PCM buffer as pipeline audio: the same samples,
    /// PTS taken from `AVAudioTime.hostTime` on the master clock. Returns
    /// nil when the tap time carries no host time or Core Media rejects
    /// the buffer — that buffer is skipped, never restamped with a
    /// synthetic position.
    static func capturedAudio(from buffer: AVAudioPCMBuffer, at when: AVAudioTime) -> CapturedAudio? {
        guard when.isHostTimeValid else { return nil }
        let presentationTime = CMClockMakeHostTimeFromSystemUnits(when.hostTime)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBufferOut: CMSampleBuffer?
        guard
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: buffer.format.formatDescription,
                sampleCount: CMItemCount(buffer.frameLength),
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBufferOut
            ) == noErr,
            let sampleBuffer = sampleBufferOut,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: buffer.audioBufferList
            ) == noErr
        else { return nil }
        return CapturedAudio(sampleBuffer: sampleBuffer)
    }

    /// Translates a device UID into its Core Audio device identifier, or
    /// nil if no connected device matches (for microphones,
    /// `AVCaptureDevice.uniqueID` is the Core Audio UID).
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidQualifier = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &uidQualifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifier,
                &dataSize,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// The production authorization seam: asks TCC for microphone access
    /// (prompting on first use).
    private static let requestMicrophoneAccess: @Sendable () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
