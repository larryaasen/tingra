//
//  MediaPlugIn.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraEventBus
import TingraPlugInKit

/// The first-party media plug-in: registers the still image, movie, and
/// text providers through the host's media seam (ARCHITECTURE.md, "Media
/// inputs and the Library's Media tab"). Every further content type is one
/// more ``MediaInputProvider``, first- or third-party.
public struct MediaPlugIn: PlugIn {
    /// The plug-in's stable identifier; also its event domain.
    public static let plugInID = PlugInID(rawValue: "com.moonwink.tingra.media")

    /// The event domain the media inputs report under.
    static let domain = EventDomain(plugInID.rawValue)

    /// The stable identifier.
    public var id: PlugInID { Self.plugInID }

    /// The user-facing name.
    public let name = "Media"

    /// Creates the plug-in.
    public init() {}

    /// Registers the three providers, reporting each as a `trace` event.
    ///
    /// Throws if the registry rejects one (a duplicate identifier, or a
    /// host with no media registry); the host's loader reports that as an
    /// `error` event and the engine keeps running. **Registration is all or
    /// nothing**, the generator plug-in's rule: the providers registered
    /// before a rejection are removed again before the error propagates.
    public func activate(in context: PlugInContext) async throws {
        let providers: [any MediaInputProvider] = [
            ImageMediaProvider(clock: context.clock, eventBus: context.eventBus),
            MovieMediaProvider(clock: context.clock, eventBus: context.eventBus),
            TextMediaProvider(clock: context.clock, eventBus: context.eventBus),
        ]
        var registered: [MediaProviderID] = []
        do {
            for provider in providers {
                try await context.media.register(provider)
                registered.append(provider.id)
                context.eventBus.trace(
                    "media.providerRegistered",
                    domain: .capture,
                    params: [
                        "id": .string(provider.id.rawValue),
                        "name": .string(provider.name),
                        "contentTypes": .string(provider.contentTypes.map(\.identifier).joined(separator: ",")),
                    ]
                )
            }
        } catch {
            for id in registered.reversed() {
                await context.media.unregister(id)
            }
            context.eventBus.trace(
                "media.registrationRolledBack",
                domain: .capture,
                params: ["removed": .int(registered.count), "reason": .string(String(describing: error))]
            )
            throw error
        }
    }
}
