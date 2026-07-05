//
//  ProbeAndStreamKeyTests.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import ArgumentParser
import Foundation
import Testing
import TingraPlugInKit

@testable import TingraCLI

/// Tests for `probe`'s argument surface and the shared stream key reader.
struct ProbeAndStreamKeyTests {
    // MARK: - Probe argument parsing

    @Test("probe parses a destination URL with a key")
    func probeParsesURLAndKey() throws {
        let probe = try Probe.parse(["--url", "rtmp://localhost:1935/live", "--key", "k"])
        #expect(probe.url == "rtmp://localhost:1935/live")
        #expect(probe.key == "k")
    }

    @Test("probe rejects an unsupported URL scheme as a usage error")
    func probeRejectsBadScheme() {
        #expect(throws: (any Error).self) {
            _ = try Probe.parse(["--url", "http://example.com/live"])
        }
    }

    @Test("probe rejects more than one key source as a usage error")
    func probeRejectsConflictingKeySources() {
        #expect(throws: (any Error).self) {
            _ = try Probe.parse(["--url", "rtmp://h/app", "--key", "k", "--key-stdin"])
        }
    }

    @Test("probe rejects --verbose with --quiet as a usage error")
    func probeRejectsVerboseQuietConflict() {
        #expect(throws: (any Error).self) {
            _ = try Probe.parse(["--url", "rtmp://h/app", "--verbose", "--quiet"])
        }
    }

    // MARK: - StreamKey

    @Test("The inline option value wins when given")
    func keyFromOption() throws {
        let key = try StreamKey.read(option: "live_abc", environmentVariable: nil, stdin: false)
        #expect(key == "live_abc")
    }

    @Test("No source given resolves to nil (a destination needing no key)")
    func keyAbsent() throws {
        let key = try StreamKey.read(option: nil, environmentVariable: nil, stdin: false)
        #expect(key == nil)
    }

    @Test("A missing environment variable throws with the invalidArgument identifier")
    func keyFromMissingEnvironmentThrows() {
        #expect(throws: StreamKeyError.missingEnvironment("TINGRA_TEST_UNSET_VARIABLE")) {
            _ = try StreamKey.read(
                option: nil,
                environmentVariable: "TINGRA_TEST_UNSET_VARIABLE",
                stdin: false
            )
        }
        #expect(StreamKeyError.missingEnvironment("X").identifier == .invalidArgument)
        #expect(StreamKeyError.emptyStdin.identifier == .invalidArgument)
    }

    @Test("A set environment variable resolves to its value")
    func keyFromEnvironment() throws {
        // PATH is always present in a test process.
        let key = try StreamKey.read(option: nil, environmentVariable: "PATH", stdin: false)
        #expect(key?.isEmpty == false)
    }

    @Test("Key error descriptions name the fix, never a key value")
    func keyErrorDescriptions() {
        #expect(String(describing: StreamKeyError.emptyStdin).contains("--key-stdin"))
        #expect(String(describing: StreamKeyError.missingEnvironment("VAR")).contains("VAR"))
    }

    // MARK: - Exit code mapping for the streaming identifiers

    @Test(
        "Streaming error identifiers carry their registered exit codes",
        arguments: [
            (ErrorIdentifier.connectionFailed, Int32(75)),
            (ErrorIdentifier.connectionLost, Int32(75)),
            (ErrorIdentifier.invalidArgument, Int32(64)),
            (ErrorIdentifier.pipelineError, Int32(70)),
        ]
    )
    func identifierExitCodes(identifier: ErrorIdentifier, code: Int32) {
        #expect(identifier.exitCode == code)
    }
}
