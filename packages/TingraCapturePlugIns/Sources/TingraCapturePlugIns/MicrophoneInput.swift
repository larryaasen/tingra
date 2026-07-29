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
import TingraEventBus
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

    /// The event bus, for reporting the format the tap actually negotiated
    /// and any retried bring-up. Optional so unit tests construct an input
    /// without one; when absent the input simply reports nothing.
    private let eventBus: EventBus?

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
    ///   - eventBus: The host's event bus, for capture diagnostics. Omit it
    ///     where those are not wanted (tests).
    ///   - requestAuthorization: The authorization seam; defaults to the
    ///     real TCC request.
    init(
        device: CaptureDevice,
        eventBus: EventBus? = nil,
        requestAuthorization: @escaping @Sendable () async -> Bool = MicrophoneInput.requestMicrophoneAccess
    ) {
        self.device = device
        self.eventBus = eventBus
        self.requestAuthorization = requestAuthorization
    }

    /// The stable identifier — the device's unique ID, verbatim, so
    /// `devices --json` output works as a selector across launches.
    var id: InputID { InputID(rawValue: device.uniqueID) }

    /// The user-facing device name.
    var name: String { device.name }

    /// A microphone.
    var kind: InputKind { device.kind }

    /// A microphone produces audio only; its video stream stays the seam's
    /// already-finished default.
    var media: InputMedia { .audio }

    /// How long a started engine gets to prove its tap is alive before
    /// start() reports the configuration rejected. A running input tap
    /// delivers continuously — silence included — at ~21 ms per 1024-frame
    /// buffer at 48 kHz, so two seconds is generous headroom for a device
    /// waking up, while a tap that failed to create never fires at all.
    private static let tapVerificationWindow = Duration.seconds(2)

    /// Requests authorization, points the engine's input at this device,
    /// starts the tap, and waits for the tap's first callback as proof the
    /// capture path is actually alive.
    ///
    /// Throws ``CaptureInputError/authorizationDenied(_:_:)`` when TCC
    /// denies microphone access, ``CaptureInputError/deviceUnavailable(_:)``
    /// when the device's Core Audio identity cannot be resolved (it
    /// disconnected since discovery), and
    /// ``CaptureInputError/configurationRejected(_:_:)`` when the engine
    /// rejects the device, fails to start, or starts without a working tap
    /// (`installTap` reports failure by logging, not throwing, so a dead tap
    /// otherwise looks like a clean start — the same out-of-band-failure
    /// trap as `AVCaptureSession.startRunning`, and the same honest-error
    /// guard as the camera's `isRunning` check). Device disconnection after
    /// a successful start is a normal event, never an error.
    func start() async throws {
        guard await requestAuthorization() else {
            throw CaptureInputError.authorizationDenied(.microphone, id)
        }

        // A USB interface re-acquired moments after release can still be
        // tearing down its previous stream, so a bring-up that proves dead is
        // retried once after a settling pause. This tolerates hardware
        // settling rather than papering over a defect: every attempt is
        // verified by the same tap gate below, so a retry can only turn a
        // *provably* dead tap into a *provably* live one, and a second
        // failure still throws with the real reason.
        for attempt in 1...Self.startAttempts {
            do {
                try await attemptStart()
                return
            } catch let error as CaptureInputError {
                guard case .configurationRejected = error, attempt < Self.startAttempts else { throw error }
                // A silent retry would let a device that fails every first
                // acquisition look perfectly healthy, which is worse than
                // not retrying at all — so the recovered attempt is still
                // reported.
                eventBus?.event(
                    "input.startRetry",
                    domain: .capture,
                    params: [
                        "id": .string(id.rawValue),
                        "name": .string(name),
                        "attempt": .int(attempt),
                        "of": .int(Self.startAttempts),
                        "reason": .string(String(describing: error)),
                    ]
                )
                try? await Task.sleep(for: Self.retrySettlingPause)
            }
        }
    }

    /// How many times ``start()`` will bring the engine up before reporting
    /// the configuration rejected. Each attempt is independently verified.
    private static let startAttempts = 2

    /// How long to let the device settle before a retry — long enough for a
    /// USB interface to finish releasing its previous stream, short enough
    /// that an operator unmuting a strip does not notice.
    private static let retrySettlingPause = Duration.milliseconds(400)

    /// One bring-up attempt: builds and starts the engine, then waits for
    /// the tap's first callback as proof the capture path is alive. Throws
    /// the same errors ``start()`` documents; on any throw the engine is
    /// torn down before returning, so an attempt leaves nothing running.
    private func attemptStart() async throws {
        let (stopSignal, stopContinuation) = AsyncStream.makeStream(of: Never.self)
        let device = self.device
        let inputID = id
        let deliver: @Sendable (CapturedAudio) -> Void = { [weak self] audio in
            self?.state.withLock { $0.continuation }?.yield(audio)
        }
        // Fired by the tap on every callback, before conversion — the tap
        // firing at all is what proves it exists. Newest-1 buffering keeps
        // the unconsumed yields after verification from accumulating.
        let (tapCallbacks, tapCallback) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let eventBus = self.eventBus
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            Task {
                let engine: AVAudioEngine
                let format: AVAudioFormat
                do {
                    (engine, format) = try Self.makeRunningEngine(
                        for: device,
                        id: inputID,
                        tapFired: { tapCallback.yield(()) },
                        deliver: deliver
                    )
                } catch {
                    ready.resume(throwing: error)
                    return
                }
                guard await Self.tapDelivered(tapCallbacks) else {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    ready.resume(
                        throwing: CaptureInputError.configurationRejected(
                            inputID,
                            "the audio engine started but its tap never delivered a buffer, so the tap "
                                + "was not created — the device may be held by another app, or may have "
                                + "changed format while the engine was configuring; reselect the "
                                + "microphone to try again"
                        ))
                    return
                }
                // Reported only once the tap is proven live, so the log says
                // what is actually flowing rather than what was requested.
                // This is the fact whose absence made a wrong tap format
                // take three attempts to find: a microphone reporting its
                // own hardware's rate and channel count makes a mismatch
                // visible in the first line of a session log.
                eventBus?.event(
                    "input.format",
                    domain: .capture,
                    params: [
                        "id": .string(inputID.rawValue),
                        "sampleRate": .double(format.sampleRate),
                        "channels": .int(Int(format.channelCount)),
                    ]
                )
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

    /// Whether the tap fires within ``tapVerificationWindow`` — the
    /// proof-of-life race between the tap's first callback and the timeout.
    ///
    /// - Parameter tapCallbacks: The stream the tap yields into on every
    ///   callback.
    /// - Returns: True when the tap fired; false when the window elapsed
    ///   first.
    private static func tapDelivered(_ tapCallbacks: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in tapCallbacks { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: tapVerificationWindow)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Builds, configures, and starts the audio engine for a device.
    /// Called from (and its result confined to) the engine task.
    ///
    /// - Parameters:
    ///   - device: The discovered microphone to capture from.
    ///   - id: The input's identifier, for error reporting.
    ///   - tapFired: Called on every tap callback, before conversion — the
    ///     caller's proof the tap exists.
    ///   - deliver: Called with each converted buffer.
    /// - Returns: The running engine and the format its tap negotiated.
    private static func makeRunningEngine(
        for device: CaptureDevice,
        id: InputID,
        tapFired: @escaping @Sendable () -> Void,
        deliver: @escaping @Sendable (CapturedAudio) -> Void
    ) throws -> (engine: AVAudioEngine, format: AVAudioFormat) {
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

        // The tap format must be the *selected device's* hardware format, and
        // it is read from Core Audio rather than from the engine at all.
        // Switching the input unit's device above is an asynchronous engine
        // configuration change, so both of the node's own accessors can still
        // describe the *previous* device while it settles:
        // `outputFormat(forBus:)` is the engine's graph-side snapshot and is
        // reliably stale, and `inputFormat(forBus:)` — the hardware side — is
        // fresh only once the switch has landed, which is a race on a restart
        // against a device that is still tearing down its prior stream. A tap
        // installed with a format that disagrees with the hardware on sample
        // rate or channel count fails ("Failed to create tap, config change
        // pending!"), and `installTap` only *logs* that, so the engine starts
        // cleanly and delivers nothing. Asking the HAL for the device's own
        // stream format removes the engine — and therefore the race — from the
        // answer entirely: a Vocaster One reports its 10 ch / 48 kHz whether or
        // not `engine` has caught up yet.
        // The two ways this can fail are reported apart, because they blame
        // different parties: the device telling us nothing is the device's
        // situation, while a format we could not build from a rate and a
        // channel count is ours. Conflating them is what had an earlier
        // version of this code blaming a perfectly healthy interface for a
        // ten-channel layout it could not construct.
        guard let hardware = deviceInputDescription(deviceID) else {
            throw CaptureInputError.configurationRejected(
                id,
                "the device reported no usable input format — it may have disconnected while the "
                    + "engine was configuring"
            )
        }
        guard let format = tapFormat(sampleRate: hardware.sampleRate, channels: hardware.channels) else {
            throw CaptureInputError.configurationRejected(
                id,
                "no tap format could be built for the device's \(hardware.channels) input channels at "
                    + "\(hardware.sampleRate) Hz — this is a defect in Tingra, not a problem with the device"
            )
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            tapFired()
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
        return (engine, format)
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

    /// The device's own input stream format, straight from the HAL.
    ///
    /// This is deliberately not asked of `AVAudioEngine`: the engine's view
    /// of a just-switched input device lags the switch, and a tap installed
    /// from the lagging view is silently never created (see the call site).
    /// The HAL answers for the device itself, so the answer cannot be stale
    /// with respect to a graph reconfiguration.
    ///
    /// - Parameter deviceID: The Core Audio device to describe.
    /// - Returns: The device's input sample rate and channel count, or nil
    ///   when the device reports neither (it disconnected) or reports a
    ///   degenerate value. Building a tap format from these is
    ///   ``tapFormat(sampleRate:channels:)``, kept separate so a failure
    ///   there is reported as Tingra's rather than the device's.
    private static func deviceInputDescription(
        _ deviceID: AudioDeviceID
    ) -> (sampleRate: Double, channels: AVAudioChannelCount)? {
        guard
            let sampleRate = deviceNominalSampleRate(deviceID),
            let channels = deviceInputChannelCount(deviceID)
        else { return nil }
        return (sampleRate, channels)
    }

    /// The tap's client format for a device's rate and channel count: the
    /// canonical float32 deinterleaved form. The input node converts sample
    /// *encoding* for a tap but cannot resample or rechannel, so the rate and
    /// channel count must match the hardware exactly.
    ///
    /// The channel layout is built explicitly rather than inferred, and that
    /// is the whole point of this function existing separately:
    /// `AVAudioFormat(standardFormatWithSampleRate:channels:)` returns **nil
    /// for any channel count above two**, because there is no standard layout
    /// it can infer — and a multi-channel audio interface is exactly the case
    /// that matters here (a Vocaster One presents 10 input channels: its mic
    /// pair plus loopback and show-mix feeds). `DiscreteInOrder` is the right
    /// tag for that: the device's channels in hardware order, claiming no
    /// surround roles the mixer would misread. It is equally correct for mono
    /// and stereo, so there is one path rather than a special case.
    ///
    /// - Parameters:
    ///   - sampleRate: The device's nominal sample rate in hertz.
    ///   - channels: The device's input channel count.
    /// - Returns: The tap format, or nil for a degenerate rate or channel
    ///   count.
    static func tapFormat(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        guard sampleRate > 0, channels > 0 else { return nil }
        guard
            let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    /// The device's current nominal sample rate, or nil if it reports none.
    ///
    /// - Parameter deviceID: The Core Audio device to query.
    /// - Returns: The rate in hertz, or nil.
    private static func deviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Double(0)
        var dataSize = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    /// The device's total input channel count, summed across its input
    /// streams — the count the engine's input node presents, and the count
    /// the tap format must match.
    ///
    /// - Parameter deviceID: The Core Audio device to query.
    /// - Returns: The channel count, or nil when the device exposes no
    ///   input channels (it disconnected, or is output-only).
    private static func deviceInputChannelCount(_ deviceID: AudioDeviceID) -> AVAudioChannelCount? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(0)
        guard
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
            dataSize >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return nil }

        // An AudioBufferList is variable length, so it needs raw storage
        // sized by the query above rather than a fixed-layout value.
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, storage) == noErr else {
            return nil
        }
        let list = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.reduce(into: UInt32(0)) { $0 += $1.mNumberChannels }
        guard channels > 0 else { return nil }
        return AVAudioChannelCount(channels)
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
