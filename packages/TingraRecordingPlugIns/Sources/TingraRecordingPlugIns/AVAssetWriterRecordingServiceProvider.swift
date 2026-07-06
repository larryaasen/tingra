//
//  AVAssetWriterRecordingServiceProvider.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The local recording provider: creates an
/// ``AVAssetWriterRecordingService`` per recording for `.mov` and `.mp4`
/// targets.
///
/// The recording counterpart to `RTMPStreamingServiceProvider`: where that
/// serves URL schemes, this serves file extensions, resolved from the
/// `--record <path>` target (CLI.md, "Recording and control").
public struct AVAssetWriterRecordingServiceProvider: RecordingServiceProvider {
    /// The provider's stable identifier.
    public let id = OutputID(rawValue: "file")

    /// The user-facing name.
    public let name = "Local Recording"

    /// The file extensions this provider serves.
    public let fileExtensions = ["mov", "mp4"]

    /// Creates the provider.
    public init() {}

    /// Creates an `AVAssetWriter`-backed service for one recording.
    public func makeRecordingService(configuration: StreamConfiguration) -> any RecordingService {
        AVAssetWriterRecordingService(configuration: configuration)
    }
}
