//
//  LiveStreamRecord.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-10-07.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost

/// The stream this run of the app has on air, kept on disk from the moment it
/// goes live until it stops (ARCHITECTURE.md, "Offering to resume a stream
/// after the app dies").
///
/// A record found at launch means the last run ended while it was live — a
/// crash, a Force Quit, a `SIGKILL` — which is when the app offers to go
/// live again to the same destinations (``StreamResumeOffer``). It is written
/// when the stream session reports `stream.started`, never at Start, since a
/// session that never went live has nothing to resume; and it is removed on
/// every `stream.stopped` and at a clean quit, so it survives exactly the
/// exits the operator did not choose.
///
/// It names the project and the destinations by ID. It never holds a
/// destination's URL or a stream key.
struct LiveStreamRecord: Sendable {
    /// The file's name, beside `loaded-plug-ins.json`.
    static let fileName = "live-stream.json"

    /// The file's location.
    let fileURL: URL

    /// Creates a record over the file in a folder.
    ///
    /// - Parameter directory: The folder (Tingra's Application Support folder
    ///   by default; a test names a temporary one).
    init(directory: URL = PlugInBundleLoader.standardStateDirectory) {
        self.fileURL = directory.appending(path: Self.fileName)
    }

    /// What the file holds. The keys are spelled out, so the file's shape is
    /// the contract.
    struct Contents: Codable, Equatable, Sendable {
        /// The project document that was open when the stream went live.
        let project: URL

        /// The IDs of the destinations the session streamed to.
        let destinations: [String]

        /// When the stream went live.
        let wentLive: Date

        /// The JSON keys.
        enum CodingKeys: String, CodingKey {
            case project
            case destinations
            case wentLive
        }
    }

    /// The stream the last run left on air, or `nil` when it left no record —
    /// it was not live when it ended, or it ended cleanly. A file that does
    /// not decode reads as no record: with the project or the destinations
    /// lost there is nothing to offer.
    func read() -> Contents? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Contents.self, from: data)
    }

    /// Records the stream that just went live. Best effort: a record that
    /// cannot be written only means no offer after a crash.
    ///
    /// - Parameter contents: The project, the destinations, and the time.
    func write(_ contents: Contents) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(contents).write(to: fileURL, options: [.atomic])
    }

    /// Removes the record: the stream stopped, the app is terminating, or the
    /// launch has read it.
    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
