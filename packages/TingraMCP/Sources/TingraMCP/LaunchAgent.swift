//
//  LaunchAgent.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Darwin
import Foundation

/// A failure installing or removing the daemon's LaunchAgent. Each carries a
/// developer-facing explanation and, where relevant, the underlying cause so
/// the message states what to fix rather than leaving the user guessing.
public enum LaunchAgentError: Error, CustomStringConvertible {
    /// The `~/Library/LaunchAgents` directory could not be created.
    case directoryNotWritable(String, underlying: String)

    /// The plist could not be written to disk.
    case plistNotWritten(String, underlying: String)

    /// The plist could not be removed from disk.
    case plistNotRemoved(String, underlying: String)

    /// `launchctl` could not be executed at all.
    case launchctlNotRun(underlying: String)

    /// `launchctl` ran but reported a nonzero status for the given subcommand.
    case launchctlFailed(command: String, status: Int32, output: String)

    public var description: String {
        switch self {
        case .directoryNotWritable(let path, let underlying):
            return "Could not create the LaunchAgents directory at '\(path)': \(underlying)."
        case .plistNotWritten(let path, let underlying):
            return "Could not write the LaunchAgent plist at '\(path)': \(underlying)."
        case .plistNotRemoved(let path, let underlying):
            return "Could not remove the LaunchAgent plist at '\(path)': \(underlying)."
        case .launchctlNotRun(let underlying):
            return "Could not run launchctl: \(underlying)."
        case .launchctlFailed(let command, let status, let output):
            let detail = output.isEmpty ? "" : " (\(output))"
            return "launchctl \(command) exited \(status)\(detail)."
        }
    }
}

/// The daemon's launchd LaunchAgent: the `serve --install`/`--uninstall`
/// mechanics that register the socket-activated daemon (MCP.md, "Lifecycle:
/// launchd socket activation").
///
/// launchd owns the listening socket declared under `Sockets` and starts
/// `tingra-cli serve` on the first connection, which adopts the descriptor via
/// ``LaunchdSocket``. Socket activation (no `RunAtLoad`) means the daemon is
/// its own responsible process, so TCC prompts name Tingra rather than the
/// agent app that connected — the deciding reason for the launchd design.
public struct LaunchAgent {
    /// The LaunchAgent label (also the plist file's basename), stable under
    /// `com.moonwink.tingra.*` per CLAUDE.md.
    public static let label = "com.moonwink.tingra.serve"

    /// The absolute path to the `tingra-cli` executable launchd runs. Under
    /// Homebrew this is the stable `bin` symlink so `brew upgrade` does not
    /// strand the plist on an old Cellar path.
    public let programPath: String

    /// The Unix domain socket path launchd owns and hands to the daemon.
    public let socketPath: String

    /// Creates a LaunchAgent description.
    ///
    /// - Parameters:
    ///   - programPath: The absolute path to the `tingra-cli` executable.
    ///   - socketPath: The socket path launchd listens on and hands over.
    public init(programPath: String, socketPath: String) {
        self.programPath = programPath
        self.socketPath = socketPath
    }

    /// The per-user LaunchAgents directory: `~/Library/LaunchAgents`.
    public static var launchAgentsDirectory: URL {
        URL.libraryDirectory.appending(path: "LaunchAgents", directoryHint: .isDirectory)
    }

    /// The plist path this agent installs to.
    public static var plistURL: URL {
        launchAgentsDirectory.appending(path: "\(label).plist")
    }

    /// The launchd domain target for the current user's GUI session, e.g.
    /// `gui/501`, that `bootstrap`/`bootout` operate on.
    private static var guiDomain: String {
        "gui/\(getuid())"
    }

    /// Renders the LaunchAgent plist. Socket activation only — there is no
    /// `RunAtLoad`, so the daemon starts on the first connection, not at
    /// login, and idle-exits when quiet (MCP.md, "Idle exit"). The `Socket`
    /// key matches ``LaunchdSocket/name`` so the daemon adopts the right
    /// descriptor. `SockPathMode` is `0600` (384 decimal).
    public func plistContents() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(Self.xmlEscaped(programPath))</string>
                <string>serve</string>
            </array>
            <key>Sockets</key>
            <dict>
                <key>\(LaunchdSocket.name)</key>
                <dict>
                    <key>SockPathName</key>
                    <string>\(Self.xmlEscaped(socketPath))</string>
                    <key>SockPathMode</key>
                    <integer>384</integer>
                </dict>
            </dict>
        </dict>
        </plist>
        """
    }

    /// Installs and bootstraps the LaunchAgent: writes the plist, then loads it
    /// into the user's GUI launchd domain so the socket goes live. Re-running
    /// is safe — an already-loaded agent is booted out first.
    ///
    /// - Throws: A ``LaunchAgentError`` if the directory, plist, or `launchctl`
    ///   step cannot be completed.
    public func install() throws {
        let directory = Self.launchAgentsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LaunchAgentError.directoryNotWritable(directory.path(percentEncoded: false), underlying: "\(error)")
        }

        let plistURL = Self.plistURL
        do {
            try plistContents().write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            throw LaunchAgentError.plistNotWritten(plistURL.path(percentEncoded: false), underlying: "\(error)")
        }

        // Boot out any prior instance so a re-install reloads cleanly; a
        // not-loaded agent makes this a no-op, so its failure is ignored.
        _ = try? Self.runLaunchctl(["bootout", "\(Self.guiDomain)/\(Self.label)"])
        let bootstrap = try Self.runLaunchctl(["bootstrap", Self.guiDomain, plistURL.path(percentEncoded: false)])
        guard bootstrap.status == 0 else {
            throw LaunchAgentError.launchctlFailed(
                command: "bootstrap", status: bootstrap.status, output: bootstrap.output)
        }
    }

    /// Boots out the LaunchAgent and removes its plist. A not-loaded agent or a
    /// missing plist is treated as already uninstalled, not an error.
    ///
    /// - Throws: A ``LaunchAgentError`` if the plist exists but cannot be
    ///   removed.
    public static func uninstall() throws {
        // Ignore bootout failure: the agent may not be loaded, which is fine.
        _ = try? runLaunchctl(["bootout", "\(guiDomain)/\(label)"])
        let plistURL = plistURL
        guard FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            throw LaunchAgentError.plistNotRemoved(plistURL.path(percentEncoded: false), underlying: "\(error)")
        }
    }

    /// Runs `launchctl` with the given arguments, returning its exit status and
    /// combined output. Synchronous — this is one-shot setup, not the daemon
    /// runtime path.
    ///
    /// - Throws: ``LaunchAgentError/launchctlNotRun(underlying:)`` if the
    ///   process cannot be launched.
    private static func runLaunchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw LaunchAgentError.launchctlNotRun(underlying: "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    /// XML-escapes a path for safe embedding in the plist's `<string>` values.
    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
            .replacing(">", with: "&gt;")
    }
}
