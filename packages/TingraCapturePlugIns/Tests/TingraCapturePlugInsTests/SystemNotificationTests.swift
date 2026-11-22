//
//  SystemNotificationTests.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Synchronization
import Testing

@testable import TingraCapturePlugIns

/// The process-wide system registrations behind window and display inputs,
/// subscribed from a background task as an input's start does: the
/// `NSWorkspace` observers, fed a notification posted on the workspace's own
/// center, and the CoreGraphics display reconfiguration callback, whose
/// fan-out is driven directly once it is installed.
@Suite("System notification observers", .timeLimit(.minutes(1)))
struct SystemNotificationTests {
    @Test("An application arrival subscribed from a background task reaches its subscriber")
    func applicationArrivalReachesSubscriber() async throws {
        let arrivals = await Task.detached { ApplicationActivity.liveArrivals() }.value
        await ApplicationActivity.observersInstalled()
        let bundleIdentifier = await MainActor.run { () -> String? in
            let workspace = NSWorkspace.shared
            guard let application = workspace.runningApplications.first(where: { $0.bundleIdentifier != nil })
            else { return nil }
            workspace.notificationCenter.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: workspace,
                userInfo: [NSWorkspace.applicationUserInfoKey: application]
            )
            return application.bundleIdentifier
        }
        let expected = ApplicationArrival(bundleIdentifier: try #require(bundleIdentifier))
        // A real activation on the Mac may arrive first; wait for the posted one.
        var received = false
        for await arrival in arrivals where arrival == expected {
            received = true
            break
        }
        #expect(received)
    }

    @Test("A display sleep subscribed from a background task reaches its subscriber")
    func displaySleepReachesSubscriber() async {
        let events = await Task.detached { DisplayPower.liveEvents() }.value
        await DisplayPower.observersInstalled()
        await MainActor.run {
            let workspace = NSWorkspace.shared
            workspace.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: workspace)
        }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .slept)
    }

    @Test("A display connected after a background-task subscription is reported once the callback is installed")
    func displayConnectionReachesSubscriber() async {
        let display = DisplayDevice(
            uniqueID: "5C1D3E2A-7B4F-4C8E-9A10-2F6B8D4E1C33",
            name: "Display 3",
            pixelWidth: 1920,
            pixelHeight: 1080
        )
        let connected = Mutex<[DisplayDevice]>([])
        let changes = await Task.detached {
            DisplayEventReporter.liveChanges(enumerateDisplays: { connected.withLock { $0 } })
        }.value
        await DisplayReconfiguration.callbackInstalled()
        connected.withLock { $0 = [display] }
        DisplayReconfiguration.fanOut()
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() == DisplayChange(kind: .connected, display: display))
    }
}
