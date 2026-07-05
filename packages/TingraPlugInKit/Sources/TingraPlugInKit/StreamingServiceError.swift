//
//  StreamingServiceError.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The error currency of ``StreamingService/start(to:)``: every
/// implementation reports start failures through these cases so callers
/// map them to stable error identifiers without knowing the concrete
/// service (see CLI.md, "Error identifiers").
///
/// Messages are developer-facing descriptions of cause and fix, and must
/// never contain a stream key.
public enum StreamingServiceError: Error, Equatable {
    /// The destination cannot be streamed to as given — for example, an
    /// RTMP URL with no stream key and no stream name in its path. Maps
    /// to `invalidArgument` (exit 64).
    case unsupportedDestination(String)

    /// The transport connection or the publish handshake was rejected or
    /// unreachable: bad host, bad stream key, refused publish. Maps to
    /// `connectionFailed` (exit 75).
    case connectionRejected(String)
}

extension StreamingServiceError {
    /// The stable error identifier this error reports under (see CLI.md,
    /// "Error identifiers").
    public var identifier: ErrorIdentifier {
        switch self {
        case .unsupportedDestination: return .invalidArgument
        case .connectionRejected: return .connectionFailed
        }
    }
}

extension StreamingServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedDestination(let message):
            return message
        case .connectionRejected(let message):
            return message
        }
    }
}
