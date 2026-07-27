//
//  RTMPStreamingServiceProvider.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The RTMP/RTMPS output provider: creates a
/// ``HaishinKitStreamingService`` per stream for `rtmp://` and `rtmps://`
/// destinations.
///
/// SRT is served by its sibling ``SRTStreamingServiceProvider`` (roadmap
/// step 8); this provider is unchanged by that addition.
public struct RTMPStreamingServiceProvider: StreamingServiceProvider {
    /// The provider's stable identifier.
    public let id = OutputID(rawValue: "rtmp")

    /// The user-facing name.
    public let name = "RTMP Output"

    /// The destination URL schemes this provider serves.
    public let schemes = ["rtmp", "rtmps"]

    /// Creates the provider.
    public init() {}

    /// Creates a HaishinKit-backed service for one stream session.
    public func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService {
        HaishinKitStreamingService(configuration: configuration)
    }
}
