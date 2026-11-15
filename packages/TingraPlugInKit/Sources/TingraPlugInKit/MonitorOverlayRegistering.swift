//
//  MonitorOverlayRegistering.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The host's monitor overlay registration seam, as a plug-in sees it:
/// where a plug-in registers the ``MonitorOverlayProvider``s it
/// contributes during ``PlugIn/activate(in:)`` (PLUGINS.md, Decision 53).
public protocol MonitorOverlayRegistering: Sendable {
    /// Registers a monitor overlay provider contributed by a plug-in.
    ///
    /// Throws a descriptive error if the provider cannot be accepted: for
    /// example, when its identifier is already registered.
    ///
    /// - Parameter provider: The provider to register.
    func register(_ provider: any MonitorOverlayProvider) async throws
}

/// The monitor overlay seam of a host with no monitor, such as the CLI or
/// the daemon: it accepts every provider and keeps none (PLUGINS.md,
/// Decision 53).
///
/// Unlike ``UnavailableMediaRegistry`` it never throws. A monitor overlay
/// only means something where a monitor draws, so a plug-in that registers
/// one beside other capabilities must activate the same way in every front
/// end, not fail where nothing could ever show it. The default
/// ``PlugInContext/monitorOverlays``.
public struct DiscardingMonitorOverlayRegistry: MonitorOverlayRegistering {
    /// Creates the registry.
    public init() {}

    /// Accepts the provider and keeps nothing.
    ///
    /// - Parameter provider: The provider, which no one will read.
    public func register(_ provider: any MonitorOverlayProvider) async throws {}
}
