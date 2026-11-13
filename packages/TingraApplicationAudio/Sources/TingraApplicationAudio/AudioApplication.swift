//
//  AudioApplication.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// One running application that has at least one audio process, with every
/// process that belongs to it — what a picker lists and what a tap captures.
///
/// **Which processes belong to an application** (ARCHITECTURE.md,
/// "Application audio", A5): every Core Audio process whose executable lives
/// inside the application's bundle. That takes in the main process and the
/// helpers an application ships inside itself — a browser plays from helper
/// processes in its own bundle, not from its main process. A process outside
/// any application bundle is never claimed, which deliberately leaves out the
/// system's shared processes (one shared WebKit process plays for every app
/// built on it): tapping it would capture other applications too. That gap is
/// recorded rather than worked around.
///
/// **What counts as an application.** Not every `.app` that opens audio is
/// one an operator chooses: macOS's own background components (the login
/// window, Siri, Control Center) live under `/System/Library` and are left
/// out, as is an `.app` packaged inside another kind of bundle (a simulator
/// runtime's, a framework's), which is that bundle's part. Applications in
/// `/System/Applications` stay.
public struct AudioApplication: Sendable, Equatable, Identifiable {
    /// The application's bundle identifier — its identity across launches.
    public let bundleIdentifier: String

    /// The application's user-facing name.
    public let name: String

    /// The path of the application's bundle, e.g. `/Applications/Name.app`.
    public let bundlePath: String

    /// The application's audio processes now, in the HAL's order.
    public let processes: [AudioProcess]

    /// The bundle identifier.
    public var id: String { bundleIdentifier }

    /// Creates an application record.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The bundle identifier.
    ///   - name: The user-facing name.
    ///   - bundlePath: The bundle's path.
    ///   - processes: Its audio processes.
    public init(bundleIdentifier: String, name: String, bundlePath: String, processes: [AudioProcess]) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
        self.processes = processes
    }

    /// What a bundle says about itself: its identifier and its name.
    public struct BundleDescription: Sendable, Equatable {
        /// The bundle identifier.
        public let bundleIdentifier: String

        /// The user-facing name.
        public let name: String

        /// Creates a description.
        ///
        /// - Parameters:
        ///   - bundleIdentifier: The bundle identifier.
        ///   - name: The user-facing name.
        public init(bundleIdentifier: String, name: String) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
        }
    }

    /// The running applications that have an audio process now, by name.
    ///
    /// - Parameter excludingProcess: A process whose application is left out
    ///   — the caller's own, so an app never lists itself (default: this
    ///   process).
    /// - Returns: The applications.
    /// - Throws: ``ApplicationAudioError/processListUnavailable(status:)``.
    public static func running(
        excludingProcess: pid_t = ProcessInfo.processInfo.processIdentifier
    ) throws(ApplicationAudioError) -> [AudioApplication] {
        applications(from: try AudioProcess.current(), excludingProcess: excludingProcess, describe: describeBundle)
    }

    /// The running application with a bundle identifier, with its audio
    /// processes now, or nil when it has none — it is not running, or has
    /// not opened audio yet.
    ///
    /// - Parameter bundleIdentifier: The application's bundle identifier.
    /// - Returns: The application, or nil.
    /// - Throws: ``ApplicationAudioError/processListUnavailable(status:)``.
    public static func running(bundleIdentifier: String) throws(ApplicationAudioError) -> AudioApplication? {
        try running(excludingProcess: -1).first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Groups processes into the applications they belong to — the
    /// membership rule as a pure function, so it is tested without a HAL.
    ///
    /// Each process belongs to the **outermost** `.app` bundle on its
    /// executable's path, so a helper application nested inside a browser's
    /// bundle counts as the browser's. A process on no `.app` path, or whose
    /// bundle does not describe itself, belongs to nothing. The application
    /// that holds `excludingProcess` is left out entirely.
    ///
    /// - Parameters:
    ///   - processes: The HAL's processes.
    ///   - excludingProcess: The process whose application is left out.
    ///   - describe: Reads a bundle's identifier and name from its path.
    /// - Returns: The applications, by name.
    public static func applications(
        from processes: [AudioProcess],
        excludingProcess: pid_t,
        describe: (String) -> BundleDescription?
    ) -> [AudioApplication] {
        var order: [String] = []
        var members: [String: [AudioProcess]] = [:]
        var excludedBundle: String?
        for process in processes {
            guard let bundlePath = applicationBundlePath(forExecutable: process.executablePath) else { continue }
            if process.processIdentifier == excludingProcess { excludedBundle = bundlePath }
            if members[bundlePath] == nil { order.append(bundlePath) }
            members[bundlePath, default: []].append(process)
        }
        // Two copies of one application (an installed one and a build of it)
        // share a bundle identifier, which is the record's identity, so they
        // merge: the first bundle found names it, and every copy's processes
        // are tapped.
        var applications: [AudioApplication] = []
        for bundlePath in order {
            guard bundlePath != excludedBundle, let description = describe(bundlePath) else { continue }
            let processes = members[bundlePath] ?? []
            if let index = applications.firstIndex(where: { $0.bundleIdentifier == description.bundleIdentifier }) {
                let existing = applications[index]
                applications[index] = AudioApplication(
                    bundleIdentifier: existing.bundleIdentifier, name: existing.name,
                    bundlePath: existing.bundlePath, processes: existing.processes + processes)
            } else {
                applications.append(
                    AudioApplication(
                        bundleIdentifier: description.bundleIdentifier, name: description.name,
                        bundlePath: bundlePath, processes: processes))
            }
        }
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The outermost application bundle on an executable's path —
    /// `/Applications/Name.app` for `/Applications/Name.app/Contents/MacOS/Name`
    /// and for a helper nested deeper inside it.
    ///
    /// - Parameter executablePath: An absolute executable path.
    /// - Returns: The bundle's path, or nil when the path passes through no
    ///   `.app` directory, lies in macOS's own `/System/Library`, or reaches
    ///   its `.app` through another kind of bundle.
    public static func applicationBundlePath(forExecutable executablePath: String) -> String? {
        guard executablePath.hasPrefix("/"), !executablePath.hasPrefix(systemLibraryPrefix) else { return nil }
        var components: [Substring] = []
        for component in executablePath.split(separator: "/", omittingEmptySubsequences: true) {
            components.append(component)
            if component.hasSuffix(".app"), component.count > 4 {
                return "/" + components.joined(separator: "/")
            }
            if let dot = component.lastIndex(of: "."),
                enclosingBundleExtensions.contains(component[component.index(after: dot)...].lowercased())
            {
                return nil
            }
        }
        return nil
    }

    /// Where macOS keeps its own background components.
    static let systemLibraryPrefix = "/System/Library/"

    /// The bundle kinds whose `.app` contents are their own parts rather
    /// than applications an operator would choose.
    static let enclosingBundleExtensions: Set<String> = [
        "framework", "simruntime", "xpc", "bundle", "appex", "plugin", "kext",
    ]

    /// The production bundle description: the bundle's identifier from its
    /// Info.plist and the name the Finder shows for it.
    ///
    /// - Parameter bundlePath: The bundle's path.
    /// - Returns: The description, or nil for a bundle with no identifier.
    @Sendable static func describeBundle(_ bundlePath: String) -> BundleDescription? {
        guard let bundleIdentifier = Bundle(path: bundlePath)?.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        var name = FileManager.default.displayName(atPath: bundlePath)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return BundleDescription(bundleIdentifier: bundleIdentifier, name: name)
    }
}
