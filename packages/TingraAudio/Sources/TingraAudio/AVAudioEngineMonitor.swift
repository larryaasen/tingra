//
//  AVAudioEngineMonitor.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import TingraPlugInKit

/// The first-party ``AudioMonitor``: mixed blocks scheduled onto an
/// `AVAudioPlayerNode` inside an `AVAudioEngine` whose output node is bound
/// to the operator's chosen device.
///
/// An actor, because `AVAudioEngine` and its nodes are reference types with
/// no `Sendable` conformance and the monitor is driven from the app's
/// program-audio drain: actor isolation is the seam's mutual exclusion, so
/// the engine never needs an `@unchecked Sendable` escape (ARCHITECTURE.md
/// reserves that for `CapturedFrame`/`CapturedAudio` alone).
///
/// **Drift is bounded by dropping, never by waiting.** The mix tick is paced
/// by the master clock at exactly `blockFrames / sampleRate`, while the
/// output device runs on its own crystal — over a long session the two
/// diverge. The monitor therefore counts the blocks it has scheduled but not
/// yet heard played back, and a block arriving while that backlog is at
/// ``maximumScheduledBlocks`` is **dropped**: the mixer's one-second intake
/// cap mirrored at the output, so drift costs a bounded, audible glitch
/// rather than monitor latency that grows all session. An underrun is not a
/// case to handle — a player node with nothing scheduled renders silence and
/// keeps running.
///
/// Like the capture inputs' hardware paths, this type is **seam-only**: it
/// is exercised through real devices rather than unit tests, which is
/// exactly why ``AudioMonitor`` exists for a double to stand in for.
public actor AVAudioEngineMonitor: AudioMonitor {
    /// The most blocks that may sit scheduled and unheard before new ones
    /// are dropped — four blocks, ≈85 ms at the default mix format. Small
    /// enough that monitor latency stays unobtrusive, large enough to ride
    /// out ordinary scheduling jitter.
    static let maximumScheduledBlocks = 4

    /// The running engine and its player node, while monitoring.
    private var running: Running?

    /// The device currently being monitored through, while monitoring.
    private var currentDevice: AudioMonitorDevice?

    /// The monitor level — the operator's listening volume, applied to the
    /// player node and never to the program mix.
    private var level: Double = 1

    /// The blocks scheduled but not yet reported played back — the backlog
    /// the drop rule bounds.
    private var scheduledBlocks = 0

    /// The single active device-list consumer, while attached.
    private var deviceContinuation: AsyncStream<[AudioMonitorDevice]>.Continuation?

    /// Whether the Core Audio device-list listener is installed.
    private var isListeningForDevices = false

    /// One running output path.
    private struct Running {
        /// The engine driving the output device.
        let engine: AVAudioEngine

        /// The node the mixed blocks are scheduled onto.
        let player: AVAudioPlayerNode

        /// The format the scheduled buffers must carry.
        let format: AVAudioFormat
    }

    /// Creates a monitor. Nothing opens until ``start(device:format:)``, so
    /// an operator who never monitors pays nothing.
    public init() {}

    /// Stops the output path and removes the device listener on teardown.
    deinit {
        deviceContinuation?.finish()
    }

    // MARK: Devices

    public func availableDevices() async -> [AudioMonitorDevice] {
        Self.outputDevices()
    }

    public func deviceUpdates() async -> AsyncStream<[AudioMonitorDevice]> {
        let (stream, continuation) = AsyncStream<[AudioMonitorDevice]>.makeStream()
        let previous = deviceContinuation
        deviceContinuation = continuation
        previous?.finish()
        installDeviceListenerIfNeeded()
        return stream
    }

    /// Installs the Core Audio listener that reports device-list changes, so
    /// a connected or disconnected device reaches the caller as an event
    /// rather than through a poll loop (CLAUDE.md). Installed once, on the
    /// first ``deviceUpdates()`` consumer.
    private func installDeviceListenerIfNeeded() {
        guard !isListeningForDevices else { return }
        isListeningForDevices = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // A nil queue lets Core Audio pick where the block runs; it does no
        // work of its own beyond handing the change to the actor.
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil) {
            [weak self] _, _ in
            Task { await self?.deviceListChanged() }
        }
    }

    /// Yields the current device list to the attached consumer after Core
    /// Audio reported a change.
    private func deviceListChanged() {
        deviceContinuation?.yield(Self.outputDevices())
    }

    // MARK: Lifecycle

    public func start(device: AudioMonitorDevice, format: MixFormat) async throws {
        if let currentDevice, currentDevice.uid == device.uid, running != nil { return }
        stop()

        guard let deviceID = Self.deviceID(forUID: device.uid) else {
            throw AudioMonitorError.deviceNotFound(uid: device.uid)
        }
        guard
            let playFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate, channels: 2)
        else {
            throw AudioMonitorError.couldNotStart(
                uid: device.uid, reason: "the mix format \(format.sampleRate) Hz stereo is not representable")
        }

        let engine = AVAudioEngine()
        do {
            // The device must be bound before the graph is built: the output
            // node adopts the device's own format when it is connected.
            try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
        } catch {
            throw AudioMonitorError.couldNotStart(uid: device.uid, reason: error.localizedDescription)
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        player.volume = Float(min(1, max(0, level)))

        do {
            try engine.start()
        } catch {
            engine.detach(player)
            throw AudioMonitorError.couldNotStart(uid: device.uid, reason: error.localizedDescription)
        }
        player.play()

        running = Running(engine: engine, player: player, format: playFormat)
        currentDevice = device
        scheduledBlocks = 0
    }

    public func stop() {
        guard let running else { return }
        running.player.stop()
        running.engine.stop()
        running.engine.detach(running.player)
        self.running = nil
        currentDevice = nil
        scheduledBlocks = 0
    }

    public func setLevel(_ level: Double) {
        self.level = level
        running?.player.volume = Float(min(1, max(0, level)))
    }

    // MARK: Playback

    public func play(_ audio: CapturedAudio) {
        guard let running else { return }
        // Bounded backlog: past the cap the block is dropped rather than
        // deepening the gap between what the operator sees and hears.
        guard scheduledBlocks < Self.maximumScheduledBlocks else { return }
        guard let buffer = Self.pcmBuffer(from: audio, format: running.format) else { return }

        scheduledBlocks += 1
        running.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { await self?.blockPlayedBack() }
        }
    }

    /// Records that one scheduled block has finished playing, freeing a slot
    /// in the backlog.
    private func blockPlayedBack() {
        scheduledBlocks = max(0, scheduledBlocks - 1)
    }

    /// Converts one mixed block into the player node's currency. Returns nil
    /// when the block's format does not match the running graph (a device or
    /// format change mid-flight) or Core Media declines the copy — that
    /// block is simply not heard, never a failure that propagates.
    ///
    /// - Parameters:
    ///   - audio: The mixed program block.
    ///   - format: The format the player node was connected with.
    /// - Returns: The block as a PCM buffer, or nil.
    private static func pcmBuffer(from audio: CapturedAudio, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let description = audio.sampleBuffer.formatDescription else { return nil }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard sourceFormat.isEqual(format) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(audio.sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                audio.sampleBuffer,
                at: 0,
                frameCount: Int32(frames),
                into: buffer.mutableAudioBufferList
            ) == noErr
        else { return nil }
        return buffer
    }

    // MARK: Core Audio device enumeration

    /// Every audio **output** device the system currently has, in Core
    /// Audio's own order.
    ///
    /// Enumerated through the Core Audio HAL because there is no
    /// `AVCaptureDevice`-style discovery for output devices on macOS
    /// (`AVAudioSession` is iOS-only). A device qualifies when it has at
    /// least one output channel, which is what excludes microphones and
    /// other input-only devices from the monitor picker.
    ///
    /// - Returns: The available output devices.
    static func outputDevices() -> [AudioMonitorDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr
        else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard isMonitorable(deviceID),
                let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
                let name = stringProperty(kAudioObjectPropertyName, of: deviceID)
            else { return nil }
            return AudioMonitorDevice(uid: uid, name: name)
        }
    }

    /// Resolves a persisted device UID to the Core Audio device it names
    /// right now, by matching against the live device list — the same walk
    /// ``outputDevices()`` makes, so a uid can only resolve to a device the
    /// picker would also have offered.
    ///
    /// - Parameter uid: The device's stable UID.
    /// - Returns: The device's current id, or nil when it is not connected.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr
        else { return nil }

        return deviceIDs.first { isMonitorable($0) && stringProperty(kAudioDevicePropertyDeviceUID, of: $0) == uid }
    }

    /// Whether a device belongs in the monitor picker: it can play audio out,
    /// and it is not one of macOS's own private aggregates.
    ///
    /// The two tests live together so ``outputDevices()`` and
    /// ``deviceID(forUID:)`` can never disagree — a persisted UID must not
    /// resolve to a device the picker would not have offered.
    ///
    /// - Parameter deviceID: The device to test.
    /// - Returns: Whether the operator may monitor through it.
    private static func isMonitorable(_ deviceID: AudioObjectID) -> Bool {
        hasOutputChannels(deviceID) && !isPrivateAggregate(deviceID)
    }

    /// Whether a device is one of macOS's **private aggregates** — the
    /// `CADefaultDeviceAggregate-<pid>-0` devices Core Audio builds inside a
    /// process that runs an `AVAudioEngine`.
    ///
    /// Ours qualifies: starting the monitor makes macOS create one, it carries
    /// output channels, and the device-list listener fires as it appears — so
    /// without this test the picker gains a row naming the monitor's own
    /// plumbing a moment after the operator turns monitoring on, and offers it
    /// as something to monitor *through*. Confirmed by instrumenting the real
    /// HAL rather than inferred (ARCHITECTURE.md, "Private aggregate audio
    /// devices in the monitor picker").
    ///
    /// - Parameter deviceID: The device to test.
    /// - Returns: Whether the device is a private aggregate.
    private static func isPrivateAggregate(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFDictionary? = nil
        var dataSize = UInt32(MemoryLayout<CFDictionary?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        // A device with no composition at all is not an aggregate — every
        // real output device takes this path.
        guard status == noErr, let composition = value as? [String: Any] else { return false }
        return isPrivateComposition(composition)
    }

    /// Whether an aggregate device's composition marks it private.
    ///
    /// Split out from the HAL read so the rule itself is unit-testable
    /// without any audio hardware — which matters because it is the rule that
    /// must **not** catch a user's own aggregate. Verified in both
    /// directions on real devices: macOS's private aggregate carries
    /// `private = 1`, while an aggregate created the way Audio MIDI Setup
    /// creates one carries no `private` key at all. A user-authored aggregate
    /// is a legitimate thing to monitor through, so absence means public.
    ///
    /// - Parameter composition: The device's
    ///   `kAudioAggregateDevicePropertyComposition` dictionary.
    /// - Returns: Whether the aggregate is one of macOS's private ones.
    static func isPrivateComposition(_ composition: [String: Any]) -> Bool {
        switch composition[kAudioAggregateDeviceIsPrivateKey as String] {
        case let flag as Int: return flag != 0
        case let flag as Bool: return flag
        case let flag as NSNumber: return flag.boolValue
        default: return false
        }
    }

    /// Whether a device carries any output channels — the test that keeps
    /// input-only devices out of the monitor picker.
    ///
    /// - Parameter deviceID: The device to test.
    /// - Returns: Whether the device can play audio out.
    private static func hasOutputChannels(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0
        else { return false }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, storage) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Reads one of a device's string properties.
    ///
    /// - Parameters:
    ///   - selector: The property to read (a `CFString`-valued one).
    ///   - deviceID: The device to read it from.
    /// - Returns: The property's value, or nil when the device does not
    ///   carry it.
    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
