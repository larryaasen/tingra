//
//  LaunchAgentTests.swift
//  TingraMCP
//
//  Created by Larry Aasen on 2026-07-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing

@testable import TingraMCP

/// The daemon's launchd LaunchAgent (MCP.md, "Lifecycle"): the plist it renders
/// for socket activation, and the socket-adoption fallback. Only the pure,
/// side-effect-free surface is exercised — `install`/`uninstall` touch
/// `~/Library/LaunchAgents` and launchctl, so they are not run here.
@Suite("LaunchAgent")
struct LaunchAgentTests {
    /// A representative agent for rendering assertions.
    private let agent = LaunchAgent(
        programPath: "/opt/homebrew/bin/tingra-cli",
        socketPath: "/Users/tester/Library/Application Support/Tingra/tingra.sock"
    )

    @Test("plist carries the label, program, and serve argument")
    func plistCarriesIdentity() {
        let plist = agent.plistContents()
        #expect(plist.contains("<string>\(LaunchAgent.label)</string>"))
        #expect(plist.contains("<string>/opt/homebrew/bin/tingra-cli</string>"))
        #expect(plist.contains("<string>serve</string>"))
    }

    @Test("plist declares the socket under the key the daemon adopts")
    func plistDeclaresSocket() {
        let plist = agent.plistContents()
        // The Sockets entry key must match the name LaunchdSocket.activate uses.
        #expect(plist.contains("<key>\(LaunchdSocket.name)</key>"))
        #expect(plist.contains("<key>SockPathName</key>"))
        #expect(plist.contains("/Users/tester/Library/Application Support/Tingra/tingra.sock"))
        // 0600, expressed as its decimal 384.
        #expect(plist.contains("<key>SockPathMode</key>"))
        #expect(plist.contains("<integer>384</integer>"))
    }

    @Test("plist is socket-activated, not run at login")
    func plistHasNoRunAtLoad() {
        // Socket activation starts the daemon on first connect; RunAtLoad would
        // start it at login and defeat idle-exit (MCP.md, "Idle exit").
        #expect(!agent.plistContents().contains("RunAtLoad"))
    }

    @Test("plist XML-escapes special characters in paths")
    func plistEscapesPaths() {
        let odd = LaunchAgent(
            programPath: "/Users/a&b/bin/tingra-cli",
            socketPath: "/tmp/x<y>.sock"
        )
        let plist = odd.plistContents()
        #expect(plist.contains("/Users/a&amp;b/bin/tingra-cli"))
        #expect(plist.contains("/tmp/x&lt;y&gt;.sock"))
        #expect(!plist.contains("a&b/bin"))
    }

    @Test("plist path is under the per-user LaunchAgents directory")
    func plistURLLocation() {
        let path = LaunchAgent.plistURL.path(percentEncoded: false)
        #expect(path.hasSuffix("/Library/LaunchAgents/\(LaunchAgent.label).plist"))
    }

    @Test("socket adoption returns nil when not launched by launchd")
    func adoptionReturnsNilOutsideLaunchd() {
        // `swift test` is not socket-activated, so there is no descriptor to
        // adopt and the daemon falls back to manual mode.
        #expect(LaunchdSocket.activate() == nil)
    }
}
