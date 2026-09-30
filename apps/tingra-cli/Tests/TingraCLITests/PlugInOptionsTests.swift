//
//  PlugInOptionsTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-09-28.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Testing
import TingraHost

@testable import TingraCLI

@Suite("PlugInOptions")
struct PlugInOptionsTests {
    @Test("every command that loads plug-ins accepts --safe-mode")
    func everyCommandAcceptsSafeMode() throws {
        #expect(try Devices.parse(["--safe-mode"]).plugIns.safeMode)
        #expect(try Probe.parse(["--url", "rtmp://localhost/live", "--safe-mode"]).plugIns.safeMode)
        #expect(try Stream.parse(["--url", "rtmp://localhost/live", "--dry-run", "--safe-mode"]).plugIns.safeMode)
        #expect(try Serve.parse(["--safe-mode"]).plugIns.safeMode)
    }

    @Test("without --safe-mode a command loads bundles normally")
    func safeModeIsOffByDefault() throws {
        let options = try Devices.parse([]).plugIns

        #expect(!options.safeMode)
        #expect(options.bundleLoader(for: "devices").safeMode == nil)
    }

    @Test("--safe-mode makes a loader in safe mode, triggered by the flag, naming its command")
    func safeModeLoader() throws {
        let loader = try Serve.parse(["--safe-mode"]).plugIns.bundleLoader(for: "serve")

        #expect(loader.safeMode == .flag)
        #expect(loader.frontEnd == "tingra-cli serve")
    }

    @Test("serve rejects --safe-mode with --install or --uninstall, since the daemon keeps no safe mode")
    func serveInstallRejectsSafeMode() {
        #expect(throws: (any Error).self) { try Serve.parse(["--install", "--safe-mode"]) }
        #expect(throws: (any Error).self) { try Serve.parse(["--uninstall", "--safe-mode"]) }
    }
}
