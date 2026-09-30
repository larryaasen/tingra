//
//  PlugInApplicationStore.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// The app-scoped storage of app-tier plug-ins on this Mac: one JSON file
/// per plug-in under `~/Library/Application Support/Tingra/Plug-in Data/<id>/`
/// (PLUGINS.md, Decisions 7 and 38). Never secrets — those are Keychain items
/// through ``PlugInSecretStore``.
///
/// Not the `Plug-ins` folder beside it: that one holds the host-tier bundles
/// the operator installs (Decision 25), and Remove All Data deletes this
/// folder whole, which must never take an installed plug-in with it.
struct PlugInApplicationStore: Sendable {
    /// The folder holding one subfolder per plug-in.
    let directory: URL

    /// The file name inside a plug-in's folder.
    static let fileName = "application.json"

    /// The production folder, `~/Library/Application Support/Tingra/Plug-in Data`
    /// — named once, so the Data settings pane lists the folder the store
    /// writes.
    static let defaultDirectory = URL.applicationSupportDirectory.appending(path: "Tingra/Plug-in Data")

    /// Creates a store.
    ///
    /// - Parameter directory: The folder holding one subfolder per plug-in
    ///   (default: ``defaultDirectory``).
    init(directory: URL = defaultDirectory) {
        self.directory = directory
    }

    /// The file a plug-in's value lives in.
    func fileURL(for plugIn: PlugInID) -> URL {
        directory.appending(path: plugIn.rawValue).appending(path: Self.fileName)
    }

    /// The stored value, or nil when the file is absent or unreadable (an
    /// unreadable file is reported by the caller; a plug-in gets a fresh
    /// start rather than a crash).
    func value(for plugIn: PlugInID) -> JSONValue? {
        guard let data = try? Data(contentsOf: fileURL(for: plugIn)) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Writes the value, creating the plug-in's folder; nil removes the
    /// file.
    ///
    /// - Throws: A file-system error.
    func setValue(_ value: JSONValue?, for plugIn: PlugInID) throws {
        let url = fileURL(for: plugIn)
        guard let value else {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
