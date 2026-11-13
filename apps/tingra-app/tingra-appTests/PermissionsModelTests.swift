//
//  PermissionsModelTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization
import Testing
import TingraEventBus
import TingraHost

@testable import TingraApp

/// A scripted authorization seam: answers from a table the test edits, and
/// records every request so a test can assert the model asked.
private final class ScriptedAuthorization: AuthorizationChecking {
    /// The answer per permission; a permission with no entry reads as
    /// `notDetermined`.
    private let answers: Mutex<[AuthorizationPermission: AuthorizationStatus]>

    /// Every permission `request(_:)` was called for, in order.
    private let requested = Mutex<[AuthorizationPermission]>([])

    /// Creates the seam with its starting answers.
    init(_ answers: [AuthorizationPermission: AuthorizationStatus]) {
        self.answers = Mutex(answers)
    }

    /// Changes one permission's answer, as System Settings would.
    func set(_ permission: AuthorizationPermission, to status: AuthorizationStatus) {
        answers.withLock { $0[permission] = status }
    }

    /// The permissions requested so far.
    var requests: [AuthorizationPermission] { requested.withLock { $0 } }

    func status(of permission: AuthorizationPermission) -> AuthorizationStatus {
        answers.withLock { $0[permission] ?? .notDetermined }
    }

    func request(_ permission: AuthorizationPermission) async -> AuthorizationStatus {
        requested.withLock { $0.append(permission) }
        // A request grants: the operator clicked Allow.
        set(permission, to: .granted)
        return .granted
    }

    /// The error every ``reset(_:)`` throws, or nil to reset normally.
    var resetFailure: AuthorizationError? {
        get { resetFailureBox.withLock { $0 } }
        set { resetFailureBox.withLock { $0 = newValue } }
    }

    /// Storage for ``resetFailure``.
    private let resetFailureBox = Mutex<AuthorizationError?>(nil)

    /// Every permission `reset(_:)` was called for, in order.
    var resets: [AuthorizationPermission] { resetBox.withLock { $0 } }

    /// Storage for ``resets``.
    private let resetBox = Mutex<[AuthorizationPermission]>([])

    func reset(_ permission: AuthorizationPermission) async throws {
        resetBox.withLock { $0.append(permission) }
        if let resetFailure { throw resetFailure }
        // The system forgot: the permission reads undecided again.
        set(permission, to: .notDetermined)
    }
}

@MainActor
@Suite("PermissionsModel")
struct PermissionsModelTests {
    /// Collects every event the bus carries while a body runs.
    private func recordedEvents(during body: (EventBus) async -> Void) async -> [EventBusEvent] {
        let bus = EventBus()
        let stream = bus.events()
        await body(bus)
        bus.shutdown()
        var events: [EventBusEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("before the first refresh no permission has a status")
    func unreadBeforeRefresh() {
        let model = PermissionsModel(authorization: ScriptedAuthorization([:]), eventBus: EventBus())
        #expect(model.status(of: .camera) == nil)
        #expect(model.statuses.isEmpty)
    }

    @Test("the first refresh reads every permission and reports the whole picture once")
    func firstRefreshReportsStatus() async {
        let authorization = ScriptedAuthorization([.camera: .granted, .microphone: .denied])
        var granted: Set<AuthorizationPermission> = []
        let events = await recordedEvents { bus in
            let model = PermissionsModel(authorization: authorization, eventBus: bus)
            granted = model.refresh()
            #expect(model.status(of: .camera) == .granted)
            #expect(model.status(of: .microphone) == .denied)
            #expect(model.status(of: .screenRecording) == .notDetermined)
        }
        // Nothing is *newly* granted on a first read — there was no "before".
        #expect(granted.isEmpty)
        let status = events.filter { $0.name == "authorization.status" }
        #expect(status.count == 1)
        #expect(status.first?.params?["camera"] == .string("granted"))
        #expect(status.first?.params?["microphone"] == .string("denied"))
        #expect(status.first?.params?["screenRecording"] == .string("notDetermined"))
        #expect(events.contains { $0.name == "authorization.changed" } == false)
    }

    @Test("a refresh that finds nothing changed reports nothing and grants nothing")
    func unchangedRefreshIsSilent() async {
        let authorization = ScriptedAuthorization([.camera: .granted])
        var granted: Set<AuthorizationPermission> = [.camera]
        let events = await recordedEvents { bus in
            let model = PermissionsModel(authorization: authorization, eventBus: bus)
            model.refresh()
            granted = model.refresh()
        }
        #expect(granted.isEmpty)
        #expect(events.count { $0.name.hasPrefix("authorization.") } == 1)
    }

    @Test("a permission granted in System Settings comes back as newly granted, with one change event")
    func grantReportsChange() async {
        let authorization = ScriptedAuthorization([.screenRecording: .denied])
        var granted: Set<AuthorizationPermission> = []
        let events = await recordedEvents { bus in
            let model = PermissionsModel(authorization: authorization, eventBus: bus)
            model.refresh()
            authorization.set(.screenRecording, to: .granted)
            granted = model.refresh()
            #expect(model.status(of: .screenRecording) == .granted)
        }
        #expect(granted == [.screenRecording])
        let changes = events.filter { $0.name == "authorization.changed" }
        #expect(changes.count == 1)
        #expect(changes.first?.params?["permission"] == .string("screenRecording"))
        #expect(changes.first?.params?["from"] == .string("denied"))
        #expect(changes.first?.params?["to"] == .string("granted"))
    }

    @Test("a permission revoked in System Settings reports the change but is not newly granted")
    func revocationIsNotAGrant() async {
        let authorization = ScriptedAuthorization([.microphone: .granted])
        var granted: Set<AuthorizationPermission> = [.microphone]
        let events = await recordedEvents { bus in
            let model = PermissionsModel(authorization: authorization, eventBus: bus)
            model.refresh()
            authorization.set(.microphone, to: .denied)
            granted = model.refresh()
        }
        #expect(granted.isEmpty)
        let changes = events.filter { $0.name == "authorization.changed" }
        #expect(changes.count == 1)
        #expect(changes.first?.params?["to"] == .string("denied"))
    }

    @Test("request() asks the seam, then refreshes and reports the grant")
    func requestAsksAndRefreshes() async {
        let authorization = ScriptedAuthorization([.camera: .notDetermined])
        var granted: Set<AuthorizationPermission> = []
        let events = await recordedEvents { bus in
            let model = PermissionsModel(authorization: authorization, eventBus: bus)
            model.refresh()
            granted = await model.request(.camera)
            #expect(model.status(of: .camera) == .granted)
        }
        #expect(authorization.requests == [.camera])
        #expect(granted == [.camera])
        #expect(events.contains { $0.name == "authorization.changed" && $0.params?["to"] == .string("granted") })
    }

    @Test("reset() asks the seam to forget, then refreshes to Not Requested and reports both")
    func resetForgetsAndReports() async throws {
        let authorization = ScriptedAuthorization([.camera: .granted, .microphone: .denied])
        var statusAfter: AuthorizationStatus?
        let events = await recordedEvents { bus in
            let model = PermissionsModel(authorization: authorization, eventBus: bus)
            model.refresh()
            await model.reset(.camera)
            statusAfter = model.status(of: .camera)
        }

        #expect(authorization.resets == [.camera])
        #expect(statusAfter == .notDetermined)
        let reset = try #require(events.first { $0.name == "authorization.reset" })
        #expect(reset.group == .event)
        #expect(reset.params?["permission"] == .string("camera"))
        let changed = try #require(events.first { $0.name == "authorization.changed" })
        #expect(changed.params?["from"] == .string("granted"))
        #expect(changed.params?["to"] == .string("notDetermined"))
    }

    @Test("a reset the system refuses is an error event naming the reason, and the status is re-read as it stands")
    func refusedResetIsReported() async throws {
        let authorization = ScriptedAuthorization([.camera: .granted])
        authorization.resetFailure = .resetRefused(permission: .camera, status: 1, output: "refused")
        var statusAfter: AuthorizationStatus?
        let events = await recordedEvents { bus in
            let model = PermissionsModel(authorization: authorization, eventBus: bus)
            model.refresh()
            await model.reset(.camera)
            statusAfter = model.status(of: .camera)
        }

        #expect(statusAfter == .granted)
        let error = try #require(events.first { $0.name == "authorization.reset" })
        #expect(error.group == .error)
        #expect(error.params?["permission"] == .string("camera"))
        #expect(
            error.params?["error"]
                == .string(
                    AuthorizationError.resetRefused(permission: .camera, status: 1, output: "refused").description)
        )
        #expect(!events.contains { $0.name == "authorization.changed" })
    }

    @Test("every permission names the TCC service tccutil resets it by")
    func tccServiceNames() {
        #expect(AuthorizationPermission.camera.tccServiceName == "Camera")
        #expect(AuthorizationPermission.microphone.tccServiceName == "Microphone")
        #expect(AuthorizationPermission.screenRecording.tccServiceName == "ScreenCapture")
        #expect(AuthorizationPermission.systemAudioRecording.tccServiceName == "AudioCapture")
    }

    @Test("a status the system cannot read shows as granted once a capture proves it, and only then")
    func resolvedStatus() {
        #expect(PermissionsModel.resolved(.unknown, proven: false) == .unknown)
        #expect(PermissionsModel.resolved(.unknown, proven: true) == .granted)
        // A status the system can read is never overridden.
        #expect(PermissionsModel.resolved(.denied, proven: true) == .denied)
        #expect(PermissionsModel.resolved(.notDetermined, proven: true) == .notDetermined)
    }

    @Test("an application's first audio turns System Audio Recording granted, reported once")
    func provenGrant() async {
        let authorization = ScriptedAuthorization([.systemAudioRecording: .unknown])
        let events = await recordedEvents { bus in
            let model = PermissionsModel(authorization: authorization, eventBus: bus)
            model.refresh()
            #expect(model.status(of: .systemAudioRecording) == .unknown)
            model.noteGranted(.systemAudioRecording)
            #expect(model.status(of: .systemAudioRecording) == .granted)
            model.noteGranted(.systemAudioRecording)
            // A later refresh keeps what the capture proved.
            model.refresh()
            #expect(model.status(of: .systemAudioRecording) == .granted)
        }
        let changes = events.filter { $0.name == "authorization.changed" }
        #expect(changes.count == 1)
        #expect(changes.first?.params?["permission"] == .string("systemAudioRecording"))
        #expect(changes.first?.params?["from"] == .string("unknown"))
        #expect(changes.first?.params?["to"] == .string("granted"))
    }

    @Test("resetting a proven permission forgets the proof")
    func resetForgetsProof() async {
        let authorization = ScriptedAuthorization([.systemAudioRecording: .unknown])
        let model = PermissionsModel(authorization: authorization, eventBus: EventBus())
        model.refresh()
        model.noteGranted(.systemAudioRecording)
        await model.reset(.systemAudioRecording)
        // The scripted system forgets by reading undecided; the real one
        // keeps reading unknown, and either way the proof is gone.
        authorization.set(.systemAudioRecording, to: .unknown)
        model.refresh()
        #expect(model.status(of: .systemAudioRecording) == .unknown)
    }

    @Test("every permission points at its own Privacy & Security pane, System Audio Recording at Screen Recording's")
    func systemSettingsURLs() throws {
        let urls = try AuthorizationPermission.allCases.map { try #require($0.systemSettingsURL) }
        #expect(urls.allSatisfy { $0.scheme == "x-apple.systempreferences" })
        // macOS files System Audio Recording in the Screen & System Audio
        // Recording pane, so those two share a URL; every other is distinct.
        let distinct = try AuthorizationPermission.allCases.filter { $0 != .systemAudioRecording }
            .map { try #require($0.systemSettingsURL).absoluteString }
        #expect(Set(distinct).count == distinct.count)
        #expect(
            try #require(AuthorizationPermission.screenRecording.systemSettingsURL).query == "Privacy_ScreenCapture")
        #expect(
            AuthorizationPermission.systemAudioRecording.systemSettingsURL
                == AuthorizationPermission.screenRecording.systemSettingsURL)
    }
}
