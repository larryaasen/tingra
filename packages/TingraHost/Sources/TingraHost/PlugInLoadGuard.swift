//
//  PlugInLoadGuard.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Darwin
import Foundation
import TingraPlugInKit

/// One running process, told apart from a later process that reuses its
/// process id by when it started.
public struct ProcessIdentity: Codable, Sendable, Equatable {
    /// The process id.
    public let processID: Int32

    /// When the process started, in microseconds since 1970, as the kernel
    /// records it.
    public let startTime: Int64

    /// Creates an identity.
    ///
    /// - Parameters:
    ///   - processID: The process id.
    ///   - startTime: When the process started, in microseconds since 1970.
    public init(processID: Int32, startTime: Int64) {
        self.processID = processID
        self.startTime = startTime
    }

    /// The JSON keys, spelled out so the marker's shape is the contract.
    enum CodingKeys: String, CodingKey {
        case processID
        case startTime
    }

    /// This process.
    public static let current: ProcessIdentity = {
        let processID = getpid()
        return ProcessIdentity(processID: processID, startTime: startTime(of: processID) ?? 0)
    }()

    /// Whether this process is still running: a process with this id exists
    /// and started when this one did, so it is not a later process that
    /// reuses the id.
    public var isRunning: Bool {
        Self.startTime(of: processID) == startTime
    }

    /// When a process started, in microseconds since 1970, or `nil` when no
    /// process has that id.
    ///
    /// - Parameter processID: The process id.
    static func startTime(of processID: Int32) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        // The kernel answers a process id no process has with success and
        // nothing copied, so the size, not the status, says it is gone.
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec)
    }
}

/// What a front end writes before loading a bundle's code, and removes once
/// the bundle's `activate` returns (PLUGINS.md, Decision 33).
///
/// A marker still on disk after its process is gone says that process died
/// inside that bundle's load or activation.
public struct PlugInLoadMarker: Codable, Sendable, Equatable {
    /// The plug-in the bundle declares.
    public let id: PlugInID

    /// The bundle's path, home folder as `~`.
    public let path: String

    /// The code directory hash of the build being loaded.
    public let cdHash: String

    /// The front end loading it, such as `Tingra` or `tingra-cli serve`.
    public let frontEnd: String

    /// The process loading it.
    public let process: ProcessIdentity

    /// Creates a marker.
    ///
    /// - Parameters:
    ///   - id: The plug-in the bundle declares.
    ///   - path: The bundle's path, home folder as `~`.
    ///   - cdHash: The code directory hash of the build being loaded.
    ///   - frontEnd: The front end loading it.
    ///   - process: The process loading it.
    public init(id: PlugInID, path: String, cdHash: String, frontEnd: String, process: ProcessIdentity) {
        self.id = id
        self.path = path
        self.cdHash = cdHash
        self.frontEnd = frontEnd
        self.process = process
    }

    /// The JSON keys, spelled out so the marker's shape is the contract.
    enum CodingKeys: String, CodingKey {
        case id
        case path
        case cdHash
        case frontEnd
        case process
    }
}

/// The load-crash guard's markers: one file per process, in
/// `~/Library/Application Support/Tingra/plug-in-loads/`, naming the one
/// bundle that process is loading (PLUGINS.md, Decision 33).
///
/// A process loads one bundle at a time, so one marker per process names
/// exactly one culprit. The window is milliseconds for a well-behaved
/// bundle; anything that ends the process inside it is the bundle's doing,
/// a Ctrl-C and a hang killed from outside included.
public struct PlugInLoadGuard: Sendable {
    /// The folder's name inside Tingra's Application Support folder.
    public static let folderName = "plug-in-loads"

    /// The folder holding the markers.
    public let directory: URL

    /// The process this guard writes markers for.
    let process: ProcessIdentity

    /// Creates a guard.
    ///
    /// - Parameters:
    ///   - directory: The folder holding the markers.
    ///   - process: The process markers are written for (this one by
    ///     default).
    public init(directory: URL, process: ProcessIdentity = .current) {
        self.directory = directory
        self.process = process
    }

    /// The marker file for a process, named for its id and its start, so a
    /// later process reusing the id never overwrites a dead one's marker.
    ///
    /// - Parameter process: The process.
    func markerURL(for process: ProcessIdentity) -> URL {
        directory.appending(path: "\(process.processID)-\(process.startTime).json")
    }

    /// Writes this process's marker, before a bundle's code loads.
    ///
    /// A marker that cannot be written leaves that one load unguarded, and
    /// the load goes ahead: refusing a bundle over Tingra's own disk trouble
    /// would blame the wrong party.
    ///
    /// - Parameter marker: The marker naming the bundle.
    func begin(_ marker: PlugInLoadMarker) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(marker).write(to: markerURL(for: process), options: [.atomic])
    }

    /// Removes this process's marker, once the bundle's `activate` returns.
    func end() {
        try? FileManager.default.removeItem(at: markerURL(for: process))
    }

    /// The markers whose processes are gone, oldest file name first. A
    /// marker that does not decode is not evidence against any bundle and
    /// is left alone.
    public func abandonedMarkers() -> [PlugInLoadMarker] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return
            files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(PlugInLoadMarker.self, from: data)
            }
            .filter { $0.process != process && !$0.process.isRunning }
    }

    /// Claims an abandoned marker by removing it, so that when two front
    /// ends start at once only one reports the crash.
    ///
    /// - Parameter marker: The marker.
    /// - Returns: Whether this call removed it.
    func claim(_ marker: PlugInLoadMarker) -> Bool {
        (try? FileManager.default.removeItem(at: markerURL(for: marker.process))) != nil
    }
}
