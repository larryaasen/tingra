//
//  ApplicationAudioError.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio

/// Why application audio could not be listed or captured. Each case carries
/// the Core Audio status the failing call returned, because that status is
/// the diagnosis.
public enum ApplicationAudioError: Error, Equatable, Sendable {
    /// The HAL would not give its process object list.
    case processListUnavailable(status: OSStatus)

    /// There was nothing to tap: the application has no audio process.
    case noProcesses

    /// `AudioHardwareCreateProcessTap` refused the tap.
    case tapRejected(status: OSStatus)

    /// The tap reported a format this library does not deliver — anything
    /// but 32-bit float linear PCM.
    case unsupportedFormat(String)

    /// `AudioHardwareCreateAggregateDevice` refused the tap's private
    /// aggregate.
    case aggregateRejected(status: OSStatus)

    /// `AudioDeviceCreateIOProcIDWithBlock` refused the read block.
    case ioProcRejected(status: OSStatus)

    /// `AudioDeviceStart` would not start the aggregate.
    case startRejected(status: OSStatus)
}

extension ApplicationAudioError: CustomStringConvertible {
    /// A developer-facing description naming the failing step and its status.
    public var description: String {
        switch self {
        case .processListUnavailable(let status):
            return "Core Audio did not list its audio processes (status \(status))."
        case .noProcesses:
            return "The application has no audio process to capture; it may not be running."
        case .tapRejected(let status):
            return """
                Core Audio refused the process tap (status \(status)). Process taps need macOS 14.2 or later \
                and an NSAudioCaptureUsageDescription in the app's Info.plist.
                """
        case .unsupportedFormat(let format):
            return "The process tap delivers \(format), and only 32-bit float linear PCM is supported."
        case .aggregateRejected(let status):
            return "Core Audio refused the private aggregate device for the tap (status \(status))."
        case .ioProcRejected(let status):
            return "Core Audio refused the tap's read callback (status \(status))."
        case .startRejected(let status):
            return "Core Audio would not start reading the tap (status \(status))."
        }
    }
}
