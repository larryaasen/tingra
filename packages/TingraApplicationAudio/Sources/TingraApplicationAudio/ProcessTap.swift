//
//  ProcessTap.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio
import Foundation

/// A running capture of some processes' audio: a Core Audio process tap
/// mixed down to stereo, read through a private aggregate device that holds
/// only the tap (ARCHITECTURE.md, "Application audio", A3).
///
/// **Why a tap-only aggregate.** A tap is read the way a device is, through
/// an aggregate device. Putting the application's output device in the
/// aggregate beside the tap, as published examples do, makes the aggregate
/// run at that device's rate — resampling the tap — and carry that device's
/// own input channels ahead of the tap's (found by the 2026-11-09 probe). An
/// aggregate holding only the tap runs at the tap's own rate and carries
/// exactly the tap's channels.
///
/// **Muting.** With ``start(processes:mutesProcesses:name:deliver:)``'s
/// `mutesProcesses` on, the tapped processes go silent on their own output
/// devices for as long as the tap is held, and the capture keeps the same
/// level; stopping the tap makes them audible again at once.
///
/// **No dispatch queue.** The read block is registered with no queue, so the
/// HAL calls it on its own I/O thread. The block copies each callback's
/// samples (``ApplicationAudioBuffer``) and hands them to `deliver`, which
/// must return quickly and never block.
///
/// Not `Sendable`: one owner holds it from ``start(processes:mutesProcesses:name:deliver:)``
/// to ``stop()``. ``stop()`` is also run when the value is released, so a tap
/// cannot outlive its owner and leave an application muted.
public final class ProcessTap {
    /// The tap's Core Audio object.
    private let tapID: AudioObjectID

    /// The private aggregate the tap is read through.
    private let aggregateID: AudioObjectID

    /// The registered read block.
    private let ioProcID: AudioDeviceIOProcID

    /// Whether ``stop()`` has torn everything down.
    private var isStopped = false

    /// The tap's sample rate in hertz.
    public let sampleRate: Double

    /// The tap's channel count — two, for a stereo mixdown.
    public let channelCount: Int

    /// Creates the record of a running tap; only
    /// ``start(processes:mutesProcesses:name:deliver:)`` makes one.
    ///
    /// - Parameters:
    ///   - tapID: The tap.
    ///   - aggregateID: Its aggregate.
    ///   - ioProcID: The read block.
    ///   - sampleRate: The tap's rate.
    ///   - channelCount: The tap's channels.
    private init(
        tapID: AudioObjectID,
        aggregateID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        sampleRate: Double,
        channelCount: Int
    ) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.ioProcID = ioProcID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// Stops the capture if its owner did not.
    deinit {
        stop()
    }

    /// Taps processes and starts reading them.
    ///
    /// The first tap an app makes is what shows the system's audio recording
    /// permission prompt; while it is up, and if the operator refuses it,
    /// the read block is simply not called — no status reports either
    /// (ARCHITECTURE.md, "Application audio", open questions).
    ///
    /// - Parameters:
    ///   - processes: The process objects to tap (``AudioProcess/objectID``).
    ///   - mutesProcesses: Whether the processes go silent on their own
    ///     devices while tapped.
    ///   - name: A name for the tap and its aggregate, shown in diagnostics.
    ///   - deliver: Called on the HAL's I/O thread with each callback's copy.
    /// - Returns: The running tap.
    /// - Throws: An ``ApplicationAudioError`` naming the step Core Audio
    ///   refused; everything built before it is torn down first.
    public static func start(
        processes: [AudioObjectID],
        mutesProcesses: Bool,
        name: String,
        deliver: @escaping @Sendable (ApplicationAudioBuffer) -> Void
    ) throws(ApplicationAudioError) -> ProcessTap {
        guard !processes.isEmpty else { throw .noProcesses }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = name
        description.isPrivate = true
        description.muteBehavior = mutesProcesses ? .mutedWhenTapped : .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr else { throw .tapRejected(status: tapStatus) }

        guard
            let format = CoreAudioProperty.scalar(
                tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()),
            format.mFormatID == kAudioFormatLinearPCM,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            format.mBitsPerChannel == 32,
            format.mChannelsPerFrame > 0,
            format.mSampleRate > 0
        else {
            let read = CoreAudioProperty.scalar(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            AudioHardwareDestroyProcessTap(tapID)
            throw .unsupportedFormat(read.map(describe) ?? "no readable format")
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "TingraApplicationAudio-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw .aggregateRejected(status: aggregateStatus)
        }

        let channelCount = Int(format.mChannelsPerFrame)
        let sampleRate = format.mSampleRate
        var ioProcID: AudioDeviceIOProcID?
        let ioProcStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            _, input, inputTime, _, _ in
            guard inputTime.pointee.mFlags.contains(.hostTimeValid) else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard
                let buffer = ApplicationAudioBuffer(
                    copying: list, channelCount: channelCount, sampleRate: sampleRate,
                    hostTime: inputTime.pointee.mHostTime)
            else { return }
            deliver(buffer)
        }
        guard ioProcStatus == noErr, let ioProcID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw .ioProcRejected(status: ioProcStatus)
        }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw .startRejected(status: startStatus)
        }
        return ProcessTap(
            tapID: tapID, aggregateID: aggregateID, ioProcID: ioProcID, sampleRate: sampleRate,
            channelCount: channelCount)
    }

    /// Stops reading and releases the aggregate and the tap, which makes the
    /// tapped processes audible again. Safe to call more than once.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    /// A stream format in words, for ``ApplicationAudioError/unsupportedFormat(_:)``.
    ///
    /// - Parameter format: The format.
    /// - Returns: Its rate, channels, bit depth, and flags.
    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        "\(format.mSampleRate) Hz, \(format.mChannelsPerFrame) channels, \(format.mBitsPerChannel)-bit, "
            + "format \(format.mFormatID), flags \(format.mFormatFlags)"
    }
}
