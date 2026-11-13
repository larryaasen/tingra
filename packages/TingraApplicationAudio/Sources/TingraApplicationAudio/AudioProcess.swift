//
//  AudioProcess.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreAudio
import Darwin

/// One process Core Audio knows about — an entry of the HAL's process object
/// list (`kAudioHardwarePropertyProcessObjectList`), which holds every process
/// that has opened an audio client, playing or not.
///
/// A process tap is built over these objects, never over process identifiers,
/// so ``objectID`` is what a ``ProcessTap`` takes. The executable's path is
/// what places a process inside an application's bundle
/// (``AudioApplication/applications(from:excludingProcess:describe:)``).
public struct AudioProcess: Sendable, Equatable, Hashable {
    /// The process's Core Audio object.
    public let objectID: AudioObjectID

    /// The process identifier.
    public let processIdentifier: pid_t

    /// The bundle identifier Core Audio reports for the process — empty for
    /// a process with none, such as a command-line tool.
    public let bundleIdentifier: String

    /// The absolute path of the process's executable, or empty when the
    /// system would not say (the process has exited, or belongs to another
    /// user).
    public let executablePath: String

    /// Whether the process is playing audio right now.
    public let isRunningOutput: Bool

    /// Creates a process record.
    ///
    /// - Parameters:
    ///   - objectID: The process's Core Audio object.
    ///   - processIdentifier: The process identifier.
    ///   - bundleIdentifier: Its bundle identifier, or empty.
    ///   - executablePath: Its executable's path, or empty.
    ///   - isRunningOutput: Whether it is playing audio now.
    public init(
        objectID: AudioObjectID,
        processIdentifier: pid_t,
        bundleIdentifier: String,
        executablePath: String,
        isRunningOutput: Bool
    ) {
        self.objectID = objectID
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.isRunningOutput = isRunningOutput
    }

    /// Every process in the HAL's process object list now.
    ///
    /// - Returns: The processes, in the HAL's order.
    /// - Throws: ``ApplicationAudioError/processListUnavailable(status:)``
    ///   when the HAL will not give the list.
    public static func current() throws(ApplicationAudioError) -> [AudioProcess] {
        let (objects, status) = CoreAudioProperty.objectList(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        guard status == noErr else { throw .processListUnavailable(status: status) }
        return objects.compactMap(process(for:))
    }

    /// Reads one process object, or nil when it has no process identifier
    /// (it ended between the list read and this one).
    ///
    /// - Parameter object: The process object.
    /// - Returns: The record, or nil.
    private static func process(for object: AudioObjectID) -> AudioProcess? {
        guard let pid = CoreAudioProperty.scalar(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else {
            return nil
        }
        let running = CoreAudioProperty.scalar(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0
        return AudioProcess(
            objectID: object,
            processIdentifier: pid,
            bundleIdentifier: CoreAudioProperty.string(object, kAudioProcessPropertyBundleID) ?? "",
            executablePath: executablePath(of: pid),
            isRunningOutput: running != 0
        )
    }

    /// The size `proc_pidpath` asks for: `PROC_PIDPATHINFO_MAXSIZE`, which is
    /// four times `MAXPATHLEN` and does not import into Swift as a constant.
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// A process's executable path, through `proc_pidpath`.
    ///
    /// - Parameter pid: The process.
    /// - Returns: The path, or empty when the system will not say.
    private static func executablePath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
