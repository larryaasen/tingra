//
//  RecordingCapacity.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraPlugInKit

/// How much recording a volume can still hold, in the unit an operator
/// thinks in: time (see ARCHITECTURE.md, "Recording in the app" — the
/// pre-flight free-space check).
///
/// The full-disk case is reported once it happens (`recordingFailed`), but
/// reporting it mid-take is reporting it too late — the operator has already
/// lost the part of the show they cared about. So a recording refuses to open
/// on a volume that cannot hold a usable take, and the threshold is a
/// **duration** rather than a number of gigabytes: the bitrate is already
/// known, so available bytes divide straight into recordable seconds, and
/// duration is what the operator is actually deciding about.
///
/// The same type backs the app's "time remaining" display beside the
/// recordings folder, so the number the operator reads before pressing Record
/// and the number a refusal is computed from cannot disagree.
public struct RecordingCapacity: Sendable, Equatable {
    /// The bytes still available for an important write on the volume.
    ///
    /// Read from `volumeAvailableCapacityForImportantUsage`, which accounts
    /// for space macOS can purge on demand — so a Mac that looks full to
    /// `df` but is not does not draw a spurious refusal.
    public let availableBytes: Int64

    /// The shortest recording worth starting, in seconds.
    ///
    /// Five minutes: long enough that anything shorter is not a take worth
    /// losing a show over, short enough that it never refuses a disk with
    /// real room.
    public static let minimumRecordableSeconds = 300.0

    /// Creates a capacity reading.
    ///
    /// - Parameter availableBytes: The bytes available on the volume.
    public init(availableBytes: Int64) {
        self.availableBytes = availableBytes
    }

    /// The bytes one second of program media occupies at the given
    /// compression settings — the video and audio bitrates that are enabled,
    /// converted from bits to bytes.
    ///
    /// Container overhead is not modeled: it is a low single-digit
    /// percentage of an elementary-stream-dominated file, and the estimate
    /// is deliberately the optimistic one so the check refuses only a volume
    /// that is genuinely too small rather than second-guessing the writer.
    ///
    /// - Parameter configuration: The program's compression settings.
    /// - Returns: Bytes per second, or nil when neither track is enabled and
    ///   the file would carry no media at all.
    public static func bytesPerSecond(at configuration: StreamConfiguration) -> Double? {
        var bitsPerSecond = 0
        if configuration.includesVideo {
            bitsPerSecond += configuration.videoBitsPerSecond
        }
        if configuration.includesAudio {
            bitsPerSecond += configuration.audioBitsPerSecond
        }
        guard bitsPerSecond > 0 else { return nil }
        return Double(bitsPerSecond) / 8.0
    }

    /// How long this volume can record at the given compression settings.
    ///
    /// - Parameter configuration: The program's compression settings.
    /// - Returns: The recordable duration in seconds, or nil when the
    ///   settings carry no media and the question has no answer.
    public func recordableSeconds(at configuration: StreamConfiguration) -> Double? {
        guard let bytesPerSecond = Self.bytesPerSecond(at: configuration), bytesPerSecond > 0 else { return nil }
        return Double(max(0, availableBytes)) / bytesPerSecond
    }

    /// Whether a recording at these settings is worth starting here — false
    /// only when the volume cannot hold ``minimumRecordableSeconds``.
    ///
    /// A configuration carrying no media never refuses on space: there is
    /// nothing to size, and the writer's own validation is the right place
    /// for that complaint.
    ///
    /// - Parameter configuration: The program's compression settings.
    /// - Returns: True when the recording may open.
    public func hasRoom(for configuration: StreamConfiguration) -> Bool {
        guard let seconds = recordableSeconds(at: configuration) else { return true }
        return seconds >= Self.minimumRecordableSeconds
    }

    /// Reads the capacity of the volume holding a file or folder.
    ///
    /// - Parameter url: A file URL on the volume to measure. A file that does
    ///   not exist yet is fine — the reading walks up to its parent folder,
    ///   which is what a recording about to be created needs.
    /// - Returns: The capacity, or nil when the volume cannot be measured
    ///   (an unreachable path), which callers treat as "do not refuse":
    ///   an unmeasurable volume is the writer's problem to report, not the
    ///   check's problem to guess at.
    public static func measure(at url: URL) -> RecordingCapacity? {
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard
            let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let available = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }
        return RecordingCapacity(availableBytes: available)
    }
}

/// How the recording service measures a volume — injected so the mock-backend
/// tests drive the free-space check without a disk, exactly as
/// ``RecordingWriterBackend`` already avoids one.
public typealias RecordingCapacityProbe = @Sendable (URL) -> RecordingCapacity?
