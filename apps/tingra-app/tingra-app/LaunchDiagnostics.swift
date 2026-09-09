//
//  LaunchDiagnostics.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraEventBus

/// What the first line of every app log says about the build it came from:
/// the app's version and build, the macOS version and build, and the Mac's
/// hardware model — the params of the `app.launched` event ``EngineModel``
/// emits before anything else (EVENTS.md, "Sinks"; ARCHITECTURE.md, "The log
/// file and the Logging settings pane").
///
/// A shared log that does not start by identifying the build cannot be lined
/// up with the report it came with — the lesson Auto Care Plus's
/// `app.coldstart` line taught. A value type with injectable readings rather
/// than lookups inline in the model, so the assembly rule — which keys a
/// missing reading drops, what a model identifier looks like — is tested
/// without booting an engine.
struct LaunchDiagnostics: Equatable, Sendable {
    /// The event the diagnostics are reported as (group `app`, domain
    /// `platform`).
    static let eventName = "app.launched"

    /// The app's version and build, from the bundle.
    let version: AppVersion

    /// The macOS version, `major.minor.patch` (`26.6.0`).
    let systemVersion: String

    /// The macOS build (`25G123`), or nil when the kernel does not report one.
    let systemBuild: String?

    /// The hardware model identifier (`Mac15,3`), or nil when the kernel does
    /// not report one. Apple exposes no marketing name ("MacBook Pro
    /// 14-inch") through any public API, so the identifier is the most
    /// specific device signal there is.
    let hardwareModel: String?

    /// Creates diagnostics from their parts.
    ///
    /// - Parameters:
    ///   - version: The app's version and build.
    ///   - systemVersion: The macOS version.
    ///   - systemBuild: The macOS build, or nil.
    ///   - hardwareModel: The hardware model identifier, or nil.
    init(version: AppVersion, systemVersion: String, systemBuild: String?, hardwareModel: String?) {
        self.version = version
        self.systemVersion = systemVersion
        self.systemBuild = systemBuild
        self.hardwareModel = hardwareModel
    }

    /// Reads the diagnostics of the running process.
    ///
    /// - Parameters:
    ///   - bundle: The bundle the app version is read from (the app's own by
    ///     default).
    ///   - processInfo: Where the macOS version is read from.
    init(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) {
        let system = processInfo.operatingSystemVersion
        self.init(
            version: AppVersion(bundle: bundle),
            systemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            systemBuild: Self.sysctlString("kern.osversion"),
            hardwareModel: Self.sysctlString("hw.model")
        )
    }

    /// The event params: every reading that is present, under a stable
    /// camelCase key. A missing reading drops its key rather than writing a
    /// placeholder, so a log line never claims a value nobody read.
    var params: [String: EventValue] {
        var params: [String: EventValue] = ["systemVersion": .string(systemVersion)]
        if let shortVersion = version.shortVersion { params["appVersion"] = .string(shortVersion) }
        if let build = version.build { params["appBuild"] = .string(build) }
        if let systemBuild { params["systemBuild"] = .string(systemBuild) }
        if let hardwareModel { params["hardwareModel"] = .string(hardwareModel) }
        return params
    }

    /// One string-valued kernel setting, read through `sysctl`.
    ///
    /// `hw.model` is the Mac's hardware model identifier (on a Mac `hw.machine`
    /// is only the CPU architecture, `arm64`); `kern.osversion` is the macOS
    /// build, which `ProcessInfo` exposes only inside a human-readable string.
    ///
    /// - Parameter key: The setting's name.
    /// - Returns: Its value, or nil when the kernel does not report it.
    static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        // The value is NUL-terminated; decode only what precedes the NUL.
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}
