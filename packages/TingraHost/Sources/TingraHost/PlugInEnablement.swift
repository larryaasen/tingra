//
//  PlugInEnablement.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Which host-tier plug-in bundles are off on this Mac, and why: the ones
/// the operator turned off, and the ones a crash turned off (PLUGINS.md,
/// Decision 34).
///
/// It is the operator's, not the project's: a project opened on another Mac
/// must not turn that Mac's plug-ins off. Every front end reads it through
/// ``PlugInBundleLoader``, so a bundle turned off in the app is off for
/// `serve` and the CLI too.
///
/// Entries are keyed by `PlugInID`, not path, so a plug-in updated in place
/// keeps its setting. The JSON keys are a stable contract, since the app and
/// every CLI release read the same file.
public struct PlugInEnablement: Codable, Sendable, Equatable {
    /// The plug-ins the operator turned off, in id order.
    public private(set) var disabled: [PlugInID]

    /// The bundles a crash turned off, in id order, each until its code
    /// changes or the operator turns it back on.
    public private(set) var crashed: [CrashedPlugInBundle]

    /// Creates a record.
    ///
    /// - Parameters:
    ///   - disabled: The plug-ins the operator turned off.
    ///   - crashed: The bundles a crash turned off.
    public init(disabled: [PlugInID] = [], crashed: [CrashedPlugInBundle] = []) {
        self.disabled = Self.sorted(disabled)
        self.crashed = crashed.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// The JSON keys, spelled out so the file's shape is the contract, not
    /// the property names.
    enum CodingKeys: String, CodingKey {
        case disabled
        case crashed
    }

    /// Decodes a record. Either list may be missing, since an operator may
    /// edit the file by hand and a missing list means nothing is off for
    /// that reason.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: `DecodingError` when a list or an entry is malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            disabled: try container.decodeIfPresent([PlugInID].self, forKey: .disabled) ?? [],
            crashed: try container.decodeIfPresent([CrashedPlugInBundle].self, forKey: .crashed) ?? [])
    }

    /// Encodes a record with both lists, empty or not, so the file always
    /// shows the operator its whole shape.
    ///
    /// - Parameter encoder: The encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(disabled, forKey: .disabled)
        try container.encode(crashed, forKey: .crashed)
    }

    /// Whether the operator turned a plug-in off.
    ///
    /// - Parameter id: The plug-in.
    public func isDisabled(_ id: PlugInID) -> Bool {
        disabled.contains(id)
    }

    /// The crash that turned a plug-in's bundle off, if one did.
    ///
    /// - Parameter id: The plug-in.
    public func crash(of id: PlugInID) -> CrashedPlugInBundle? {
        crashed.first { $0.id == id }
    }

    /// Turns a plug-in off. Turning off one that is already off changes
    /// nothing.
    ///
    /// - Parameter id: The plug-in.
    public mutating func disable(_ id: PlugInID) {
        guard !isDisabled(id) else { return }
        disabled = Self.sorted(disabled + [id])
    }

    /// Turns a plug-in back on, whether the operator or a crash turned it
    /// off.
    ///
    /// - Parameter id: The plug-in.
    public mutating func enable(_ id: PlugInID) {
        disabled.removeAll { $0 == id }
        forgetCrash(of: id)
    }

    /// Records the crash that turns a bundle off, replacing an earlier one
    /// for the same plug-in.
    ///
    /// - Parameter crash: The crash.
    public mutating func recordCrash(_ crash: CrashedPlugInBundle) {
        forgetCrash(of: crash.id)
        crashed = (crashed + [crash]).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    /// Forgets the crash recorded for a plug-in: its code changed, or the
    /// operator turned it back on.
    ///
    /// - Parameter id: The plug-in.
    public mutating func forgetCrash(of id: PlugInID) {
        crashed.removeAll { $0.id == id }
    }

    /// Ids in a stable order, without repeats, so the file diffs cleanly.
    private static func sorted(_ ids: [PlugInID]) -> [PlugInID] {
        Array(Set(ids)).sorted { $0.rawValue < $1.rawValue }
    }
}

/// A bundle turned off because a process died while loading or activating
/// it (PLUGINS.md, Decision 33).
public struct CrashedPlugInBundle: Codable, Sendable, Equatable {
    /// The plug-in the bundle declares.
    public let id: PlugInID

    /// The code directory hash of the build that crashed. A bundle whose
    /// code has changed since is a different build, and loads.
    public let cdHash: String

    /// The bundle's path when it crashed, home folder as `~`.
    public let path: String

    /// The front end that died, such as `Tingra` or `tingra-cli serve`.
    public let frontEnd: String

    /// When the crash was found.
    public let date: Date

    /// Creates a crash record.
    ///
    /// - Parameters:
    ///   - id: The plug-in the bundle declares.
    ///   - cdHash: The code directory hash of the build that crashed.
    ///   - path: The bundle's path, home folder as `~`.
    ///   - frontEnd: The front end that died.
    ///   - date: When the crash was found.
    public init(id: PlugInID, cdHash: String, path: String, frontEnd: String, date: Date) {
        self.id = id
        self.cdHash = cdHash
        self.path = path
        self.frontEnd = frontEnd
        self.date = date
    }

    /// The JSON keys, spelled out so the file's shape is the contract.
    enum CodingKeys: String, CodingKey {
        case id
        case cdHash
        case path
        case frontEnd
        case date
    }
}

/// Why the plug-in enablement file could not be used.
public enum PlugInEnablementStoreError: Error, Equatable, CustomStringConvertible {
    /// The file exists but is not an enablement record. The store never
    /// overwrites it, so the operator's choices can be inspected or
    /// recovered.
    case unreadable(path: String, reason: String)

    /// The file could not be written.
    case unwritable(path: String, reason: String)

    /// The cause and the fix.
    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "The file recording which plug-ins are turned off, \(path), could not be read (\(reason)). It "
                + "has been left untouched. Until it is repaired or removed, Tingra loads no plug-in bundles, since it "
                + "cannot tell which ones are turned off. Removing it turns every plug-in back on."
        case .unwritable(let path, let reason):
            return "The file recording which plug-ins are turned off, \(path), could not be written (\(reason))."
        }
    }
}

/// The plug-in enablement file, `~/Library/Application Support/Tingra/plug-ins.json`,
/// beside `destinations.json` (PLUGINS.md, Decision 34).
///
/// Every read goes to the file and nothing is cached, the
/// ``DestinationStore`` rule: the app, `serve`, and each CLI command are
/// separate processes over one file. Writes are atomic, so a crash
/// mid-write never truncates it. Two front ends writing in the same instant
/// can lose one of the two changes, as with the destinations file; the
/// writes are an operator's click and a crash found at launch, and a lost
/// crash record is found again at the next crash.
public struct PlugInEnablementStore: Sendable {
    /// The file's name.
    public static let fileName = "plug-ins.json"

    /// The file's location.
    public let fileURL: URL

    /// Creates a store.
    ///
    /// - Parameter directory: The folder holding the file (Tingra's own
    ///   Application Support folder by default; a test names a temporary
    ///   one).
    public init(directory: URL = PlugInBundleLoader.standardStateDirectory) {
        self.fileURL = directory.appending(path: Self.fileName)
    }

    /// Reads the record. A missing file means nothing is off.
    ///
    /// - Throws: ``PlugInEnablementStoreError/unreadable(path:reason:)``.
    public func read() throws -> PlugInEnablement {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return PlugInEnablement()
        }
        do {
            return try JSONDecoder.plugInEnablement.decode(PlugInEnablement.self, from: Data(contentsOf: fileURL))
        } catch {
            throw PlugInEnablementStoreError.unreadable(path: displayPath, reason: String(describing: error))
        }
    }

    /// Reads the record, applies a change, and writes it back when the
    /// change changed something.
    ///
    /// - Parameter change: The change.
    /// - Returns: The record as written.
    /// - Throws: ``PlugInEnablementStoreError``; an unreadable file is never
    ///   overwritten.
    @discardableResult
    public func update(_ change: (inout PlugInEnablement) -> Void) throws -> PlugInEnablement {
        var enablement = try read()
        let before = enablement
        change(&enablement)
        guard enablement != before else { return enablement }
        try write(enablement)
        return enablement
    }

    /// Writes the record atomically, creating the folder if needed.
    ///
    /// - Parameter enablement: The whole record.
    /// - Throws: ``PlugInEnablementStoreError/unwritable(path:reason:)``.
    func write(_ enablement: PlugInEnablement) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.plugInEnablement.encode(enablement).write(to: fileURL, options: [.atomic])
        } catch {
            throw PlugInEnablementStoreError.unwritable(path: displayPath, reason: String(describing: error))
        }
    }

    /// The file's path, home folder as `~`, for messages that may reach a
    /// shared log.
    private var displayPath: String {
        (fileURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}

extension JSONEncoder {
    /// The enablement file's encoder: pretty-printed with sorted keys so it
    /// diffs and inspects cleanly, and ISO 8601 dates a person can read.
    static var plugInEnablement: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    /// The enablement file's decoder, matching ``JSONEncoder/plugInEnablement``.
    static var plugInEnablement: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
