//
//  PlugInLaunchRecord.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost

/// The plug-in bundles this run of the app loaded, kept on disk while the app
/// runs and removed when it terminates (PLUGINS.md, Decision 32).
///
/// A record found at launch means the last run ended without terminating —
/// a crash, a Force Quit, a debugger's Stop — while bundles were loaded,
/// which is when the app offers safe mode. It is written only once the
/// bundles have loaded and activated: a crash inside a load is the
/// load-crash guard's to report, and it names the one bundle and turns it
/// off, so there is no record then and no second question (Decision 33).
/// With no bundle loaded there is no record either, since the crash was
/// Tingra's own and asking about plug-ins would mislead.
struct PlugInLaunchRecord: Sendable {
    /// The file's name, beside `plug-ins.json`.
    static let fileName = "loaded-plug-ins.json"

    /// The file's location.
    let fileURL: URL

    /// Creates a record over the file in a folder.
    ///
    /// - Parameter directory: The folder (Tingra's Application Support folder
    ///   by default; a test names a temporary one).
    init(directory: URL = PlugInBundleLoader.standardStateDirectory) {
        self.fileURL = directory.appending(path: Self.fileName)
    }

    /// What the file holds. The key is spelled out, so the file's shape is
    /// the contract.
    struct Contents: Codable, Equatable {
        /// The loaded bundles' directory names, such as `Fixture.tingraplugin`.
        let bundles: [String]

        /// The JSON keys.
        enum CodingKeys: String, CodingKey {
            case bundles
        }
    }

    /// The bundles the last run loaded, or `nil` when it left no record — it
    /// terminated normally, or it loaded no bundle. A file that does not
    /// decode counts as a record naming no bundle: something was loaded, even
    /// if the names are lost.
    func read() -> [String]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSONDecoder().decode(Contents.self, from: data))?.bundles ?? []
    }

    /// Records the bundles this run loaded. Best effort: a record that cannot
    /// be written only means no offer after a crash.
    ///
    /// - Parameter bundles: The loaded bundles' directory names.
    func write(bundles: [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(Contents(bundles: bundles)).write(to: fileURL, options: [.atomic])
    }

    /// Removes the record: the app is terminating, or the launch has read it.
    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
