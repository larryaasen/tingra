//
//  DisplayDevice.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import TingraPlugInKit

/// One connected display as discovery sees it: the stable identifier, the
/// user-facing name, and the capture geometry — the framework-free
/// reduction of a CoreGraphics display the rest of the plug-in (and its
/// tests) work with, the display counterpart to ``CaptureDevice``.
///
/// Discovery reads CoreGraphics (`CGGetActiveDisplayList`), which needs no
/// TCC authorization — like camera discovery, listing displays never
/// prompts; only capturing one does (see `DisplayInput`).
struct DisplayDevice: Sendable, Equatable {
    /// The stable identifier: the display's UUID
    /// (`CGDisplayCreateUUIDFromDisplayID`), which survives reboots and
    /// reconnections wherever the platform allows — `CGDirectDisplayID`
    /// values do not, so they never become an `InputID`.
    let uniqueID: String

    /// The user-facing display name, e.g. "Built-in Display".
    let name: String

    /// The display's current mode size in pixels. Capture runs at native
    /// pixel size; the compositor scales to the program format.
    let pixelWidth: Int

    /// The display's current mode height in pixels.
    let pixelHeight: Int
}
