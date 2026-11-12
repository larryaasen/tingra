//
//  RecordingPreferences.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraHost
import TingraPlugInKit

/// Where the operator's recordings go: **machine-local preferences**, not the
/// project document and not session state (ARCHITECTURE.md, "Recording in the
/// app").
///
/// The `MonitorPreferences` reasoning applies unchanged, one sink over. The
/// **document** would be wrong — which folder on this Mac holds the
/// recordings is not part of the show, the same test that keeps stream keys,
/// the active shot, and the staged shot out of it, and a project carried to
/// another machine would name a folder that does not exist. **Session-only**
/// would be wrong too: an operator's recordings folder does not change
/// between launches, so re-picking it every launch would be a defect rather
/// than a discipline.
struct RecordingPreferences {
    /// The defaults database the values live in (injectable, so tests run
    /// against their own suite rather than the user's).
    private let defaults: UserDefaults

    /// The recordings folder key.
    private static let folderKey = "recording.folderPath"

    /// The container-format key.
    private static let containerKey = "recording.container"

    /// The video codec key.
    private static let videoCodecKey = "recording.videoCodec"

    /// The audio bit rate key.
    private static let audioBitRateKey = "recording.audioBitsPerSecond"

    /// Where a fresh install records to: `~/Movies/Tingra Recordings`.
    ///
    /// Under `~/Movies` deliberately, over Desktop or Documents: those are
    /// TCC-protected on macOS 15 and would put a permission prompt in front
    /// of the operator's very first recording, where `~/Movies` is not
    /// protected and is already where macOS puts video. A **subfolder** since
    /// the Library's Recordings tab lists the folder (ARCHITECTURE.md, "The
    /// Recordings tab"): `~/Movies` itself would list every movie the
    /// operator owns. The first recording creates it.
    static var defaultFolder: URL {
        .moviesDirectory.appending(path: "Tingra Recordings", directoryHint: .isDirectory)
    }

    /// The container a fresh install records into — QuickTime `.mov`, the
    /// native macOS choice.
    static let defaultContainer: RecordingFile.Container = .mov

    /// The video codec a fresh install records with — H.264, which every
    /// player and editor opens.
    static let defaultVideoCodec: StreamConfiguration.VideoCodec = .h264

    /// Creates a store over a defaults database.
    ///
    /// - Parameter defaults: The database to read and write (the standard one
    ///   by default).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The folder recordings are written into.
    ///
    /// Stored as a plain path: the app is not sandboxed (CLAUDE.md), so a
    /// folder the operator picks needs no security-scoped bookmark to stay
    /// reachable across launches.
    var folder: URL {
        get {
            guard let path = defaults.string(forKey: Self.folderKey), !path.isEmpty else {
                return Self.defaultFolder
            }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        nonmutating set { defaults.set(newValue.path(percentEncoded: false), forKey: Self.folderKey) }
    }

    /// The container format recordings are muxed into. An unrecognized stored
    /// value reads as the default rather than throwing away the recording.
    var container: RecordingFile.Container {
        get {
            guard
                let raw = defaults.string(forKey: Self.containerKey),
                let container = RecordingFile.Container(rawValue: raw)
            else {
                return Self.defaultContainer
            }
            return container
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.containerKey) }
    }

    /// The video codec recordings are compressed with. An unrecognized
    /// stored value reads as the default.
    var videoCodec: StreamConfiguration.VideoCodec {
        get {
            guard
                let raw = defaults.string(forKey: Self.videoCodecKey),
                let codec = StreamConfiguration.VideoCodec(rawValue: raw)
            else {
                return Self.defaultVideoCodec
            }
            return codec
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.videoCodecKey) }
    }

    /// The audio bit rate recordings are compressed at, in bits per second:
    /// always one of the offered rates (``CompressionChoices``). Nothing
    /// stored reads as the default; a stored rate off the menu reads as the
    /// nearest one on it.
    var audioBitsPerSecond: Int {
        get {
            guard defaults.object(forKey: Self.audioBitRateKey) != nil else {
                return CompressionChoices.defaultAudioBitsPerSecond
            }
            return CompressionChoices.audioBitsPerSecond(nearest: defaults.integer(forKey: Self.audioBitRateKey))
        }
        nonmutating set { defaults.set(newValue, forKey: Self.audioBitRateKey) }
    }
}
