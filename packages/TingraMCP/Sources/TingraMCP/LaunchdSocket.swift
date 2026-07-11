//
//  LaunchdSocket.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CTingraLaunchd
import Darwin

/// Adopts the listening socket launchd created for the daemon under socket
/// activation (MCP.md, "Lifecycle: launchd socket activation").
///
/// When the LaunchAgent is installed, launchd owns the listening socket
/// declared in the plist's `Sockets` dictionary and starts `tingra-cli serve`
/// on the first connection; the daemon adopts that descriptor here rather than
/// binding its own. When `serve` is run by hand in a terminal (not under
/// launchd), ``activate(name:)`` returns nil and the caller falls back to
/// manual mode.
public enum LaunchdSocket {
    /// The socket entry name in the LaunchAgent plist's `Sockets` dictionary;
    /// must match the key ``LaunchAgent`` writes and the name passed here.
    public static let name = "Socket"

    /// Adopts the launchd-provided listening descriptor for `name`, if any.
    ///
    /// - Parameter name: The `Sockets` entry name from the LaunchAgent plist.
    /// - Returns: The first listening descriptor launchd handed over, or nil
    ///   when the process was not launched by launchd (manual mode) or the
    ///   named socket is not present.
    public static func activate(name: String = LaunchdSocket.name) -> Int32? {
        var descriptors: UnsafeMutablePointer<Int32>?
        var count: size_t = 0
        let result = name.withCString { tingra_launchd_activate_socket($0, &descriptors, &count) }
        // Non-zero result (e.g. ESRCH when not launchd-parented) or an empty
        // set means there is no socket to adopt — the caller runs manual mode.
        guard result == 0, let descriptors, count > 0 else { return nil }
        defer { free(descriptors) }
        return descriptors[0]
    }
}
