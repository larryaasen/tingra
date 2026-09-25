//
//  BundledPlugIn.swift
//  TingraPlugInKit
//
//  Created by Larry Aasen on 2026-09-23.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The entry point of a host-tier plug-in shipped as a bundle: the class the
/// bundle names as its principal class (`NSPrincipalClass` in its
/// Info.plist).
///
/// The host's bundle loader reads the bundle's Info.plist, checks it, loads
/// the code, casts `Bundle.principalClass` to `any BundledPlugIn.Type`, and
/// makes **one** instance with ``init()``. That instance then activates
/// through exactly the path a compiled-in plug-in takes, so a bundle has no
/// second lifecycle (PLUGINS.md, Decision 23). One bundle is one plug-in:
/// its ``PlugIn/id`` must equal the `com.moonwink.tingra.plug-in.id` its
/// Info.plist declares, and it is also the id its app-tier half declares.
///
/// It is a class because the Objective-C runtime can only name a class as a
/// bundle's principal class, and `init()` is required because the loader
/// has nothing to pass: everything a plug-in needs arrives in the
/// ``PlugInContext`` at activation.
///
/// ```swift
/// final class NDIPlugIn: BundledPlugIn {
///     let id = PlugInID(rawValue: "com.example.ndi")
///     let name = "NDI"
///     init() {}
///     func activate(in context: PlugInContext) async throws { … }
/// }
/// ```
///
/// Swift mangles a class's runtime name, so the bundle's `NSPrincipalClass`
/// is the class's module-qualified name (`NDIPlugIn.NDIPlugIn`), or the
/// class carries an `@objc(NDIPlugIn)` name and the plist uses that.
public protocol BundledPlugIn: PlugIn, AnyObject {
    /// Creates the plug-in. The loader calls this once per launch, before
    /// activation; do no work here that activation can do instead.
    init()
}
