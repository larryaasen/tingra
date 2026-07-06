//
//  RecordingServiceError.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The error currency of ``RecordingService/start(to:)``: every
/// implementation reports setup failures through these cases so callers map
/// them to the stable ``ErrorIdentifier/recordingFailed`` identifier without
/// knowing the concrete service (see CLI.md, "Error identifiers").
///
/// Messages are developer-facing descriptions of cause and fix. Recording
/// targets a local file, so no message ever carries a secret.
public enum RecordingServiceError: Error, Equatable {
    /// The file cannot be created or opened for writing — an unwritable or
    /// missing directory, a path that is not a file, or an unsupported
    /// container. Maps to `recordingFailed` (exit 70).
    case unwritableDestination(String)

    /// The writer refused to begin or could not be configured for the
    /// program's compression settings. Maps to `recordingFailed` (exit 70).
    case writerNotReady(String)
}

extension RecordingServiceError {
    /// The stable error identifier this error reports under (see CLI.md,
    /// "Error identifiers").
    public var identifier: ErrorIdentifier {
        switch self {
        case .unwritableDestination: return .recordingFailed
        case .writerNotReady: return .recordingFailed
        }
    }
}

extension RecordingServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unwritableDestination(let message):
            return message
        case .writerNotReady(let message):
            return message
        }
    }
}

/// The recording seam's start errors carry their identifier under the seam's
/// stability contract, so a front end maps them without importing the
/// recording plug-in.
extension RecordingServiceError: IdentifiedError {}
