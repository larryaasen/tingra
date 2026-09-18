//
//  ParameterDescribing.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// Something a plug-in registers that declares adjustable parameters — the
/// one declaration every host-tier registration shares (PLUGINS.md,
/// Decision 15), so a host draws a settings pane for a third-party input,
/// effect, or output from the ``Parameter`` descriptors alone and never
/// learns the concrete type.
///
/// The declaration is the same everywhere; where the **values** live
/// differs by what is registered, and each seam names its own place: an
/// effect's chain slot carries them (``EffectConfiguration/parameters``,
/// handed to `makeEffect` and `setParameters`); an ``Input`` receives them
/// through ``Input/setParameters(_:)`` and the app stores them per project;
/// a streaming or recording provider reads them off the target it is
/// started with (``Destination/parameters``, ``RecordingFile/parameters``).
/// A conformer that declares nothing keeps the default, an empty list, and
/// a host then draws no pane for it.
public protocol ParameterDescribing: Sendable {
    /// The parameters declared, in display order — what a host UI draws
    /// controls from and what the persisted payload's keys mean. Empty by
    /// default.
    var parameters: [Parameter] { get }
}

extension ParameterDescribing {
    /// By default nothing declares a parameter; a conformer with settings
    /// overrides this.
    public var parameters: [Parameter] { [] }
}
