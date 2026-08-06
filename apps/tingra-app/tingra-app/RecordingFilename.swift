//
//  RecordingFilename.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// Names the file a recording is written to: a date-stamped name that can
/// never overwrite an earlier take (ARCHITECTURE.md, "Recording in the app").
///
/// A fixed name would silently destroy the last show, so every recording
/// carries the moment it started. Two recordings can still land in the same
/// second — an operator stopping and immediately restarting — so a name
/// already on disk takes a numeric suffix rather than replacing what is
/// there. A recording must never overwrite a recording.
enum RecordingFilename {
    /// The stem every recording's name begins with.
    static let prefix = "Tingra"

    /// Builds the date-stamped stem for a moment: `Tingra 2026-08-06 14.03.12`.
    ///
    /// Dots separate the time components because a colon is not usable in a
    /// path, and the components are zero-padded and in descending order so
    /// the folder sorts chronologically by name. Deliberately built from
    /// `FormatStyle` parts rather than a locale-formatted date: this is a
    /// **filename**, not a label an operator reads in their own language, so
    /// it must not change shape with the locale.
    ///
    /// - Parameter date: The moment the recording starts.
    /// - Returns: The stem, without an extension.
    static func stem(at date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let year = (parts.year ?? 0).formatted(.number.precision(.integerLength(4)).grouping(.never))
        let fields = [parts.month, parts.day, parts.hour, parts.minute, parts.second]
            .map { ($0 ?? 0).formatted(.number.precision(.integerLength(2)).grouping(.never)) }
        return "\(prefix) \(year)-\(fields[0])-\(fields[1]) \(fields[2]).\(fields[3]).\(fields[4])"
    }

    /// Picks the URL a recording starting now should be written to.
    ///
    /// - Parameters:
    ///   - folder: The folder to write into.
    ///   - container: The container format, which supplies the extension.
    ///   - date: The moment the recording starts.
    ///   - exists: Whether a URL is already taken — injected so tests decide
    ///     without a disk.
    /// - Returns: A URL that was not taken when it was checked.
    static func url(
        in folder: URL,
        container: RecordingFile.Container,
        at date: Date,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> URL {
        let stem = stem(at: date)
        let first = folder.appending(path: "\(stem).\(container.rawValue)")
        guard exists(first) else { return first }
        // Two takes within one second: suffix rather than replace. The loop is
        // bounded by how many recordings can share a second, so it terminates
        // on any real disk.
        for suffix in 2... {
            let candidate = folder.appending(path: "\(stem) \(suffix).\(container.rawValue)")
            if !exists(candidate) { return candidate }
        }
        return first
    }
}
