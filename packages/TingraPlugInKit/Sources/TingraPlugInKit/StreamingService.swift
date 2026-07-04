//
//  StreamingService.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia

/// The output seam: sends compressed program media to a destination.
///
/// The HaishinKit-backed implementation lives behind this protocol as an
/// output plug-in, so no other module ever imports HaishinKit directly —
/// which keeps the dependency swappable (see ARCHITECTURE.md, "How
/// HaishinKit is incorporated").
///
/// Compression for streaming happens inside the implementation (HaishinKit
/// drives VideoToolbox internally); callers append uncompressed,
/// GPU-resident program media with timestamps on the shared session
/// timeline (see CLOCK.md, Timestamp rules).
public protocol StreamingService: Sendable {
    /// Connects and begins streaming to the destination.
    ///
    /// Throws a descriptive error if the connection or handshake is
    /// rejected (bad URL, bad stream key, unreachable host).
    func start(to destination: Destination) async throws

    /// Appends one program video frame. The frame's presentation time is
    /// already on the shared session timeline.
    func send(video frame: CapturedFrame)

    /// Appends mixed program audio. The buffer's presentation time is
    /// already on the shared session timeline.
    func send(audio buffer: CMSampleBuffer)

    /// Stops streaming: flushes compression and closes the connection.
    func stop() async
}
