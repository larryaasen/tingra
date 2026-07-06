//
//  RecordingPlugIn.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The first party local recording plug-in: contributes the
/// `AVAssetWriter`-backed recording provider through the output registration
/// seam (ARCHITECTURE.md, "The output registration seam" — recording joins
/// through the same seam as streaming output).
///
/// Like every feature, recording is a plug-in registering against the host's
/// registries; first party and third party recording outputs use the
/// identical protocol and code path.
public struct RecordingPlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.recording.avassetwriter")

    /// The plug-in's user-facing name.
    public let name = "Local Recording"

    /// Creates the plug-in.
    public init() {}

    /// Registers the `.mov`/`.mp4` recording provider, reporting the
    /// registration as a `trace` event.
    ///
    /// Throws if the registry rejects the provider (a file extension already
    /// served); the host's loader reports that as an `error` event and the
    /// engine keeps running.
    public func activate(in context: PlugInContext) async throws {
        let provider = AVAssetWriterRecordingServiceProvider()
        try await context.outputs.register(provider)
        context.eventBus.trace(
            "recording.registered",
            domain: .output,
            params: [
                "id": .string(provider.id.rawValue),
                "name": .string(provider.name),
                "fileExtensions": .string(provider.fileExtensions.joined(separator: ",")),
            ]
        )
    }
}
