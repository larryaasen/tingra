//
//  AudioApplicationTests.swift
//  TingraApplicationAudio
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing

@testable import TingraApplicationAudio

/// The membership rule: which processes belong to which application.
@Suite("AudioApplication")
struct AudioApplicationTests {
    /// A process record at a path.
    ///
    /// - Parameters:
    ///   - object: Its Core Audio object.
    ///   - pid: Its process identifier.
    ///   - path: Its executable's path.
    /// - Returns: The record.
    private func process(_ object: UInt32, pid: Int32, path: String) -> AudioProcess {
        AudioProcess(
            objectID: object, processIdentifier: pid, bundleIdentifier: "", executablePath: path,
            isRunningOutput: false)
    }

    /// Describes the fixture bundles by their file names.
    ///
    /// - Parameter path: A bundle path.
    /// - Returns: An identifier and name derived from the path, nil for the
    ///   one bundle that describes nothing.
    private func describe(_ path: String) -> AudioApplication.BundleDescription? {
        switch path {
        case "/Applications/Music Maker.app":
            return .init(bundleIdentifier: "com.example.musicmaker", name: "Music Maker")
        case "/Applications/Browser.app":
            return .init(bundleIdentifier: "com.example.browser", name: "Browser")
        case "/Applications/Tingra.app":
            return .init(bundleIdentifier: "com.example.tingra", name: "Tingra")
        case "/Applications/Anonymous.app":
            return nil
        default:
            return .init(bundleIdentifier: "com.example.other", name: "Other")
        }
    }

    @Test("A main executable belongs to its bundle")
    func mainExecutable() {
        #expect(
            AudioApplication.applicationBundlePath(forExecutable: "/Applications/Music Maker.app/Contents/MacOS/Live")
                == "/Applications/Music Maker.app")
    }

    @Test("A nested helper belongs to the outermost bundle")
    func nestedHelper() {
        let helper =
            "/Applications/Browser.app/Contents/Frameworks/Browser Framework.framework/Helpers/"
            + "Browser Helper.app/Contents/MacOS/Browser Helper"
        #expect(AudioApplication.applicationBundlePath(forExecutable: helper) == "/Applications/Browser.app")
    }

    @Test("A path through no application bundle belongs to nothing")
    func noBundle() {
        let shared =
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/"
            + "Contents/MacOS/com.apple.WebKit.GPU"
        #expect(AudioApplication.applicationBundlePath(forExecutable: shared) == nil)
        #expect(AudioApplication.applicationBundlePath(forExecutable: "/usr/bin/afplay") == nil)
        #expect(AudioApplication.applicationBundlePath(forExecutable: "") == nil)
        #expect(AudioApplication.applicationBundlePath(forExecutable: "relative/Name.app/Contents/MacOS/Name") == nil)
        #expect(AudioApplication.applicationBundlePath(forExecutable: "/Applications/.app/x") == nil)
    }

    @Test("macOS's own background components are not applications")
    func systemComponents() {
        #expect(
            AudioApplication.applicationBundlePath(
                forExecutable: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow") == nil)
        #expect(
            AudioApplication.applicationBundlePath(
                forExecutable: "/System/Applications/Messages.app/Contents/MacOS/Messages")
                == "/System/Applications/Messages.app")
    }

    @Test("An application packaged inside another kind of bundle is not an application")
    func enclosedApplications() {
        let simulator =
            "/private/var/run/mnt/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot/System/Library/"
            + "CoreServices/SpringBoard.app/SpringBoard"
        #expect(AudioApplication.applicationBundlePath(forExecutable: simulator) == nil)
        let framework = "/Library/Frameworks/Thing.framework/Versions/A/Helper.app/Contents/MacOS/Helper"
        #expect(AudioApplication.applicationBundlePath(forExecutable: framework) == nil)
        // A folder with a dot in its name is not a bundle.
        #expect(
            AudioApplication.applicationBundlePath(forExecutable: "/Users/me/My.Apps/Tool.app/Contents/MacOS/Tool")
                == "/Users/me/My.Apps/Tool.app")
    }

    @Test("Two copies of one application merge into one record")
    func copiesMerge() {
        let processes = [
            process(10, pid: 100, path: "/Applications/Music Maker.app/Contents/MacOS/Live"),
            process(11, pid: 101, path: "/Users/me/Builds/Music Maker.app/Contents/MacOS/Live"),
        ]
        let applications = AudioApplication.applications(from: processes, excludingProcess: 0) { path in
            path.hasSuffix("Music Maker.app")
                ? .init(bundleIdentifier: "com.example.musicmaker", name: "Music Maker") : nil
        }
        #expect(applications.count == 1)
        #expect(applications.first?.processes.map(\.objectID) == [10, 11])
        #expect(applications.first?.bundlePath == "/Applications/Music Maker.app")
    }

    @Test("Processes group into their applications, sorted by name")
    func grouping() {
        let processes = [
            process(10, pid: 100, path: "/Applications/Music Maker.app/Contents/MacOS/Live"),
            process(11, pid: 101, path: "/Applications/Browser.app/Contents/MacOS/Browser"),
            process(
                12, pid: 102,
                path: "/Applications/Browser.app/Contents/Frameworks/Helpers/Browser Helper.app/Contents/MacOS/Helper"),
            process(13, pid: 103, path: "/Library/Frameworks/WebKit.framework/XPCServices/GPU.xpc/GPU"),
        ]
        let applications = AudioApplication.applications(from: processes, excludingProcess: 999, describe: describe)
        #expect(applications.map(\.name) == ["Browser", "Music Maker"])
        #expect(applications.first?.processes.map(\.objectID) == [11, 12])
        #expect(applications.last?.processes.map(\.objectID) == [10])
        #expect(applications.first?.bundlePath == "/Applications/Browser.app")
        #expect(applications.first?.id == "com.example.browser")
    }

    @Test("The excluded process's application is not listed")
    func excludesOwnApplication() {
        let processes = [
            process(10, pid: 100, path: "/Applications/Music Maker.app/Contents/MacOS/Live"),
            process(20, pid: 200, path: "/Applications/Tingra.app/Contents/MacOS/Tingra"),
        ]
        let applications = AudioApplication.applications(from: processes, excludingProcess: 200, describe: describe)
        #expect(applications.map(\.bundleIdentifier) == ["com.example.musicmaker"])
    }

    @Test("A bundle that does not describe itself is not listed")
    func undescribedBundle() {
        let processes = [process(30, pid: 300, path: "/Applications/Anonymous.app/Contents/MacOS/Anonymous")]
        #expect(AudioApplication.applications(from: processes, excludingProcess: 0, describe: describe).isEmpty)
    }

    @Test("No processes list no applications")
    func empty() {
        #expect(AudioApplication.applications(from: [], excludingProcess: 0, describe: describe).isEmpty)
    }

    @Test("Equal records compare equal and differing ones do not")
    func equality() {
        let one = AudioApplication(bundleIdentifier: "a", name: "A", bundlePath: "/A.app", processes: [])
        #expect(one == AudioApplication(bundleIdentifier: "a", name: "A", bundlePath: "/A.app", processes: []))
        #expect(one != AudioApplication(bundleIdentifier: "b", name: "A", bundlePath: "/A.app", processes: []))
        let first = process(1, pid: 1, path: "/A.app/x")
        #expect(first == process(1, pid: 1, path: "/A.app/x"))
        #expect(first != process(2, pid: 1, path: "/A.app/x"))
    }
}
