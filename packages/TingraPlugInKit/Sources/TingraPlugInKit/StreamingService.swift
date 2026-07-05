//
//  StreamingService.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The output seam: sends compressed program media to a destination.
///
/// The HaishinKit-backed implementation lives behind this protocol as an
/// output plug-in, so no other module ever imports HaishinKit directly —
/// which keeps the dependency swappable (see ARCHITECTURE.md, "How
/// HaishinKit is incorporated"). Services are created per stream by a
/// ``StreamingServiceProvider`` carrying the session's
/// ``StreamConfiguration``.
///
/// Compression for streaming happens inside the implementation (HaishinKit
/// drives VideoToolbox internally); callers append uncompressed,
/// GPU-resident program media whose timestamps are already on the shared
/// session timeline — `PTS = hostTime − T0` (see CLOCK.md, Timestamp
/// rules). The service consumes those timestamps and never modifies them.
public protocol StreamingService: Sendable {
    /// Connects and begins streaming to the destination: transport
    /// connection, then the publish handshake that validates the stream key.
    ///
    /// Throws a descriptive error if the connection or handshake is
    /// rejected (bad URL, bad stream key, unreachable host). After a
    /// reported connection loss, calling `start(to:)` again on the same
    /// service reconnects with the same configuration.
    func start(to destination: Destination) async throws

    /// The service's connection events — how a connection loss after a
    /// successful start reaches the session (loss is reported, never
    /// thrown, because it happens outside any caller's call). A single
    /// consumer is expected: the stream session driving reconnect policy.
    var events: AsyncStream<StreamingServiceEvent> { get }

    /// Appends one program video frame for compression and delivery. The
    /// frame's presentation time is already on the shared session timeline.
    func send(video frame: CapturedFrame) async

    /// Appends program audio for compression and delivery. The buffer's
    /// presentation time is already on the shared session timeline.
    func send(audio buffer: CapturedAudio) async

    /// A snapshot of the service's delivery counters, read by the session
    /// when it reports periodic stats (EVENTS.md sanctions periodic stats
    /// on the bus; this is a point read of live counters, not a poll for
    /// state changes).
    func statistics() async -> StreamingStatistics

    /// Stops streaming: flushes compression and closes the connection.
    /// Safe to call more than once.
    func stop() async
}
