//
//  PlugInLoadReport.swift
//  TingraHost
//
//  Created by Larry Aasen on 2026-09-29.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Every host-tier plug-in a front end met at launch, each in one state:
/// the compiled-in ones and every bundle in the plug-in folders, joining the
/// bundle scan to the activation outcomes (PLUGINS.md, Decision 35).
///
/// It is what `tingra-cli plug-ins` prints, and its `--json` document, so
/// the JSON keys are a stable scripting contract: camelCase, spelled out,
/// never renamed. Every key is always present; an absent value is `null`.
/// The app's Plug-ins pane reads the same value.
public struct PlugInLoadReport: Codable, Sendable, Equatable {
    /// The kit version this host carries, which every bundle is checked
    /// against, as `MAJOR.MINOR.PATCH`.
    public let kitVersion: String

    /// Whether the launch was in safe mode, which loads no bundle's code.
    public let safeMode: Bool

    /// The folders scanned, in precedence order, home folder as `~`.
    public let folders: [String]

    /// Every plug-in, compiled-in ones first in activation order, then the
    /// bundles in scan order.
    public let plugIns: [Entry]

    /// Creates a report.
    ///
    /// - Parameters:
    ///   - kitVersion: The host's kit version.
    ///   - safeMode: Whether the launch was in safe mode.
    ///   - folders: The folders scanned, home folder as `~`.
    ///   - plugIns: Every plug-in met.
    public init(kitVersion: String, safeMode: Bool, folders: [String], plugIns: [Entry]) {
        self.kitVersion = kitVersion
        self.safeMode = safeMode
        self.folders = folders
        self.plugIns = plugIns
    }

    /// The JSON keys, spelled out so the document's shape is the contract.
    enum CodingKeys: String, CodingKey {
        case kitVersion
        case safeMode
        case folders
        case plugIns
    }

    /// One plug-in in a report: where it came from, and what became of it.
    public struct Entry: Codable, Sendable, Equatable {
        /// Where a plug-in came from. The raw values are the `source` key.
        public enum Source: String, Codable, Sendable, CaseIterable {
            /// Compiled into the front end.
            case compiledIn
            /// A `*.tingraplugin` bundle in a plug-in folder.
            case bundle
        }

        /// What became of a plug-in. The raw values are the `state` key.
        public enum State: String, Codable, Sendable, CaseIterable {
            /// Loaded and activated.
            case active
            /// Loaded, but its `activate` threw; ``Entry/message`` carries
            /// the error.
            case failed
            /// Refused before or while its code loaded; ``Entry/reason`` is
            /// the `plugin.bundle` reason.
            case refused
            /// Admitted but not loaded; ``Entry/reason`` is the
            /// `plugin.skipped` reason.
            case skipped
        }

        /// The plug-in id, or `nil` for a bundle that declares none.
        public let id: String?

        /// The plug-in's name: its own once loaded, else the bundle's
        /// declared name, else the bundle's directory name.
        public let name: String

        /// The bundle's `CFBundleShortVersionString`, or `nil` when it
        /// declares none or the plug-in is compiled in (it is then the front
        /// end's own version).
        public let version: String?

        /// Where it came from.
        public let source: Source

        /// The bundle's path, home folder as `~`; `nil` for a compiled-in
        /// plug-in.
        public let path: String?

        /// What became of it.
        public let state: State

        /// The stable reason for a refusal or a skip: a `plugin.bundle` or
        /// `plugin.skipped` reason. `nil` when active or failed.
        public let reason: String?

        /// The developer-facing explanation: the cause and the fix, or the
        /// error `activate` threw. `nil` when active.
        public let message: String?

        /// Defects that did not keep the plug-in out, such as an embedded
        /// kit, each as its message.
        public let warnings: [String]

        /// Creates an entry.
        ///
        /// - Parameters:
        ///   - id: The plug-in id, when known.
        ///   - name: The plug-in's name.
        ///   - version: The bundle's version, when declared.
        ///   - source: Where it came from.
        ///   - path: The bundle's path, home folder as `~`.
        ///   - state: What became of it.
        ///   - reason: The refusal or skip reason.
        ///   - message: The explanation.
        ///   - warnings: Defects that did not keep it out.
        public init(
            id: String?, name: String, version: String?, source: Source, path: String?, state: State,
            reason: String?, message: String?, warnings: [String]
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.source = source
            self.path = path
            self.state = state
            self.reason = reason
            self.message = message
            self.warnings = warnings
        }

        /// The JSON keys, spelled out so the document's shape is the
        /// contract.
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case version
            case source
            case path
            case state
            case reason
            case message
            case warnings
        }

        /// Decodes an entry. `name`, `source`, `state`, and `warnings` are
        /// required; the rest may be missing, read as `nil`.
        ///
        /// - Parameter decoder: The decoder.
        /// - Throws: `DecodingError` when a required key is missing or a
        ///   value is malformed.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                version: try container.decodeIfPresent(String.self, forKey: .version),
                source: try container.decode(Source.self, forKey: .source),
                path: try container.decodeIfPresent(String.self, forKey: .path),
                state: try container.decode(State.self, forKey: .state),
                reason: try container.decodeIfPresent(String.self, forKey: .reason),
                message: try container.decodeIfPresent(String.self, forKey: .message),
                warnings: try container.decode([String].self, forKey: .warnings))
        }

        /// Encodes every key, writing `null` for an absent value, so a
        /// script meets the same shape for every entry.
        ///
        /// - Parameter encoder: The encoder.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(version, forKey: .version)
            try container.encode(source, forKey: .source)
            try container.encode(path, forKey: .path)
            try container.encode(state, forKey: .state)
            try container.encode(reason, forKey: .reason)
            try container.encode(message, forKey: .message)
            try container.encode(warnings, forKey: .warnings)
        }
    }
}

extension PlugInLoadReport {
    /// Joins a launch's activation outcomes to its bundle scan.
    ///
    /// Each bundle the scan met becomes one entry, taking the first
    /// unclaimed outcome for its path: loaded (then active or failed, by its
    /// activation), else skipped, else refused. Claiming keeps a bundle met
    /// twice — a symbolic link to a bundle in the other folder — from
    /// reading as loaded twice. An embedded kit rides on the entry as a
    /// warning, and a crash found this launch gives its skip the crash's own
    /// message.
    ///
    /// - Parameters:
    ///   - compiledIn: Each compiled-in plug-in's activation.
    ///   - bundles: Each loaded bundle's activation, carrying its path.
    ///   - scan: What the bundle scan found.
    ///   - loader: The loader that scanned, for the kit version, the
    ///     folders, and safe mode.
    init(
        compiledIn: [PlugInActivationOutcome], bundles: [PlugInActivationOutcome], scan: PlugInBundleScan,
        loader: PlugInBundleLoader
    ) {
        var compiledInEntries: [Entry] = []
        for outcome in compiledIn {
            compiledInEntries.append(
                Entry(
                    id: outcome.plugIn.id.rawValue, name: outcome.plugIn.name, version: nil, source: .compiledIn,
                    path: nil, state: outcome.error == nil ? .active : .failed, reason: nil,
                    message: outcome.error, warnings: []))
        }

        var loaded = bundles
        var skipped = scan.skipped
        var refusals = scan.problems.filter { $0.reason.refuses && $0.reason != .crashed }
        var warnings = scan.problems.filter { !$0.reason.refuses }
        let crashes = scan.problems.filter { $0.reason == .crashed }
        /// Removes and returns the first element of `list` at `url`.
        func claim<Element>(_ list: inout [Element], at url: URL, _ urlOf: (Element) -> URL?) -> Element? {
            guard let index = list.firstIndex(where: { urlOf($0).map { Self.samePath($0, url) } ?? false }) else {
                return nil
            }
            return list.remove(at: index)
        }

        var bundleEntries: [Entry] = []
        for found in scan.found {
            let url = found.url
            let path = PlugInBundleLoader.displayPath(of: url)
            let declaredID = found.info?.id.flatMap { $0.isEmpty ? nil : $0 }
            let declaredName = found.info?.name ?? url.deletingPathExtension().lastPathComponent
            let version = found.info?.version
            if let outcome = claim(&loaded, at: url, { $0.url }) {
                let warningMessages = claim(&warnings, at: url, { $0.url }).map { [$0.message] } ?? []
                bundleEntries.append(
                    Entry(
                        id: outcome.plugIn.id.rawValue, name: outcome.plugIn.name, version: version, source: .bundle,
                        path: path, state: outcome.error == nil ? .active : .failed, reason: nil,
                        message: outcome.error, warnings: warningMessages))
            } else if let skip = claim(&skipped, at: url, { $0.url }) {
                let warningMessages = claim(&warnings, at: url, { $0.url }).map { [$0.message] } ?? []
                let crash = skip.reason == .crashed ? crashes.first { Self.samePath($0.url, url) } : nil
                bundleEntries.append(
                    Entry(
                        id: skip.id.rawValue, name: declaredName, version: version, source: .bundle, path: path,
                        state: .skipped, reason: skip.reason.rawValue, message: crash?.message ?? skip.message,
                        warnings: warningMessages))
            } else if let refusal = claim(&refusals, at: url, { $0.url }) {
                bundleEntries.append(
                    Entry(
                        id: refusal.id ?? declaredID, name: declaredName, version: version, source: .bundle,
                        path: path, state: .refused, reason: refusal.reason.rawValue, message: refusal.message,
                        warnings: []))
            }
        }

        self.init(
            kitVersion: String(describing: loader.kitVersion), safeMode: loader.safeMode != nil,
            folders: loader.folders.map(PlugInBundleLoader.displayPath(of:)),
            plugIns: compiledInEntries + bundleEntries)
    }

    /// Whether two file URLs name the same path, whatever their trailing
    /// slash or how they were built — a crash's URL is rebuilt from a
    /// marker's `~` path.
    static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        /// The path without a trailing slash.
        func normalized(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return normalized(lhs) == normalized(rhs)
    }
}

/// One plug-in's activation, as a report records it: the plug-in, where it
/// came from when it is a bundle, and the error its `activate` threw.
struct PlugInActivationOutcome: Sendable {
    /// The plug-in.
    let plugIn: any PlugIn

    /// The bundle's directory, or `nil` for a compiled-in plug-in.
    let url: URL?

    /// What `activate` threw, described, or `nil` when it activated. Kept
    /// as text, since an error need not be `Sendable`.
    let error: String?
}
