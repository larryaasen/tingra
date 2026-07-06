//
//  RecordingServiceEvent.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// A recording event reported by a ``RecordingService`` after a successful
/// start (see ``RecordingService/events``).
///
/// The recording sibling of ``StreamingServiceEvent`` — but where a stream
/// reports `connectionLost` (a recoverable loss the session may reconnect),
/// a recording reports only a terminal ``failed(reason:)``: a file has no
/// connection to reconnect, so a write failure ends the recording. The
/// session reports it and stops the recording; the stream, if any, continues
/// independently.
public enum RecordingServiceEvent: Sendable, Equatable {
    /// The recording could not continue and has stopped: a write or
    /// finalize error (a full disk, a revoked path). Terminal — the service
    /// does not retry.
    ///
    /// - Parameter reason: A developer-facing description of what went wrong
    ///   (never a secret).
    case failed(reason: String)
}
