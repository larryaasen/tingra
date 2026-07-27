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
/// HaishinKit-backed RTMP/RTMPS and SRT providers through the output
/// registration seam (ARCHITECTURE.md, "The output registration seam").
///
/// Like every feature, streaming output is a plug-in registering against
/// the host's registries — first party and third party outputs use the
/// identical protocol and code path. SRT (roadmap step 8) is a second
/// provider alongside RTMP, not a change to the RTMP path: both are
/// resolved by URL scheme through the one output registry.
public struct HaishinKitOutputPlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public let id = PlugInID(rawValue: "com.moonwink.tingra.outputs.haishinkit")

    /// The plug-in's user-facing name.
    public let name = "Streaming Output"

    /// Creates the plug-in.
    public init() {}

    /// Registers the RTMP/RTMPS and SRT providers, reporting each
    /// registration as a `trace` event.
    ///
    /// Throws if the registry rejects a provider (a scheme already served);
    /// the host's loader reports that as an `error` event and the engine
    /// keeps running.
    public func activate(in context: PlugInContext) async throws {
        try await register(RTMPStreamingServiceProvider(), in: context)
        try await register(SRTStreamingServiceProvider(), in: context)
    }

    /// Registers one provider and traces the registration.
    ///
    /// - Parameters:
    ///   - provider: The streaming service provider to register.
    ///   - context: The plug-in context carrying the output registry and
    ///     event bus.
    /// - Throws: Whatever the registry throws for a duplicate scheme.
    private func register(_ provider: any StreamingServiceProvider, in context: PlugInContext) async throws {
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
