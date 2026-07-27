//
//  SRTStreamingServiceProvider.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-24.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The SRT output provider: creates an ``SRTHaishinKitStreamingService`` per
/// stream for `srt://` destinations (roadmap step 8).
///
/// The sibling of ``RTMPStreamingServiceProvider`` behind the same
/// ``StreamingServiceProvider`` seam — the whole SRT addition is one more
/// provider the output plug-in registers, with no change to the RTMP path or
/// to any consumer, which resolves a destination through
/// `OutputRegistry.provider(forScheme:)` regardless of transport.
public struct SRTStreamingServiceProvider: StreamingServiceProvider {
    /// The provider's stable identifier.
    public let id = OutputID(rawValue: "srt")

    /// The user-facing name.
    public let name = "SRT Output"

    /// The destination URL scheme this provider serves.
    public let schemes = ["srt"]

    /// Creates the provider.
    public init() {}

    /// Creates a HaishinKit-backed SRT service for one stream session.
    public func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService {
        SRTHaishinKitStreamingService(configuration: configuration)
    }
}
