//
//  RTMPStreamingServiceProvider.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
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

    /// The well-known services this provider streams to, offered when the
    /// operator adds a destination (DESTINATIONS.md, "The first-party
    /// list"). Each URL and stream-key page was checked on 2026-09-26
    /// against the service's own documentation, OBS's maintained service
    /// list, and a DNS lookup; RTMPS wherever the service offers it, since
    /// the stream key crosses plain RTMP in the clear.
    ///
    /// Written as strings because `URL(string:)` is failable and a literal
    /// is never force-unwrapped here; a malformed one would drop its
    /// template, which the plug-in's tests catch by listing every id.
    public var destinationTemplates: [DestinationTemplate] {
        Self.templateSpecifications.compactMap { specification in
            guard let url = URL(string: specification.url) else { return nil }
            return DestinationTemplate(
                id: specification.id,
                name: specification.name,
                url: url,
                streamKeyPageURL: URL(string: specification.streamKeyPage)
            )
        }
    }

    /// The first-party templates as written: identifier, service name,
    /// published URL, and stream-key page, in alphabetical order.
    ///
    /// Twitch's URL is its auto-routing one — `live.twitch.tv` resolves to
    /// Twitch's geo-routed contribution network — so no region is chosen
    /// here, and its documented form is plain RTMP.
    private static let templateSpecifications: [(id: String, name: String, url: String, streamKeyPage: String)] = [
        (
            "facebook", "Facebook Live", "rtmps://live-api-s.facebook.com:443/rtmp/",
            "https://www.facebook.com/live/producer"
        ),
        ("twitch", "Twitch", "rtmp://live.twitch.tv/app", "https://dashboard.twitch.tv/settings/stream"),
        ("youtube", "YouTube", "rtmps://a.rtmps.youtube.com/live2", "https://www.youtube.com/live_dashboard"),
    ]

    /// Creates the provider.
    public init() {}

    /// Creates a HaishinKit-backed service for one stream session.
    public func makeStreamingService(configuration: StreamConfiguration) -> any StreamingService {
        HaishinKitStreamingService(configuration: configuration)
    }
}
