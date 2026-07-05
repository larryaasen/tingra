//
//  HaishinKitOutputPlugIn.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// The first party streaming output plug-in: contributes the
/// HaishinKit-backed RTMP/RTMPS provider through the output registration
/// seam (ARCHITECTURE.md, "The output registration seam").
///
/// Like every feature, streaming output is a plug-in registering against
/// the host's registries — first party and third party outputs use the
/// identical protocol and code path.
public struct HaishinKitOutputPlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.outputs.haishinkit")

    /// The plug-in's user-facing name.
    public let name = "Streaming Output"

    /// Creates the plug-in.
    public init() {}

    /// Registers the RTMP/RTMPS provider, reporting the registration as a
    /// `trace` event.
    ///
    /// Throws if the registry rejects the provider (a scheme already
    /// served); the host's loader reports that as an `error` event and the
    /// engine keeps running.
    public func activate(in context: PlugInContext) async throws {
        let provider = RTMPStreamingServiceProvider()
        try await context.outputs.register(provider)
        context.eventBus.trace(
            "output.registered",
            domain: .output,
            params: [
                "id": .string(provider.id.rawValue),
                "name": .string(provider.name),
                "schemes": .string(provider.schemes.joined(separator: ",")),
            ]
        )
    }
}
