//
//  SocketLocation.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Where the daemon socket lives and how its directory is secured.
///
/// `~/Library/Application Support/Tingra/tingra.sock` — fixed and short so it
/// never approaches the 104-byte `sun_path` limit (MCP.md, "The transport").
/// The containing directory is mode `0700`, so only the owning user can reach
/// the socket; the daemon's peer-uid check is defense in depth on top of it.
public enum SocketLocation {
    /// The Tingra subdirectory name under Application Support.
    public static let directoryName = "Tingra"

    /// The socket file name.
    public static let socketFileName = "tingra.sock"

    /// The directory holding the socket: `~/Library/Application Support/Tingra`.
    public static var directory: URL {
        URL.applicationSupportDirectory.appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// The socket's filesystem path.
    public static var path: String {
        directory.appending(path: socketFileName).path(percentEncoded: false)
    }

    /// Ensures the socket directory exists and is mode `0700`, creating it if
    /// needed and tightening the permissions if it already exists.
    ///
    /// - Throws: A file-system error if the directory cannot be created or
    ///   its permissions set.
    public static func prepareDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Enforce 0700 even if the directory predates this (a looser mode
        // from an earlier version, or an umask that widened creation).
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
    }
}
