//
//  EventGroup.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The routing axis of an event: what kind of event it is.
///
/// Groups are deliberately application agnostic so every sink can route any
/// event without knowing the domain that produced it. The enum is closed:
/// sinks must handle every case, so adding a group is a deliberate, rare
/// design change (see EVENTS.md).
public enum EventGroup: String, Sendable, Codable, CaseIterable {
    /// Process lifecycle: launch, version, shutdown. Default sink level: info.
    case app

    /// Any error. Default sink level: error.
    case error

    /// A notable occurrence: stream started, recording finalized. Default sink level: info.
    case event

    /// Network requests, connections, reconnects. Default sink level: debug.
    case network

    /// User tapped/clicked something (dormant until the app UI, phase 3). Default sink level: info.
    case tap

    /// Engine activity tracing for debugging. Default sink level: debug.
    case trace
}
