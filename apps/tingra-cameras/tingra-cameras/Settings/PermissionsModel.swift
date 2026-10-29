//
//  PermissionsModel.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Observation
import TingraEventBus
import TingraHost

/// Where each of the app's system permissions stands — the model behind the
/// Permissions settings pane. This app opens only cameras, so it is created
/// with the camera permission alone; the list is a parameter so the model
/// stays the main Tingra app's model, not a camera special case.
///
/// **Refreshed on events, never polled** (CLAUDE.md). macOS offers no
/// notification when a TCC grant changes, but a grant changes in exactly one
/// place, System Settings, and coming back from there is an app activation.
/// So the model re-reads every permission on `didBecomeActive`, and on the
/// settings pane appearing. Each change is reported on the bus, and the
/// permissions that newly became ``AuthorizationStatus/granted`` are handed
/// back so the preview can start the camera the grant unblocks.
@MainActor
@Observable
final class PermissionsModel {
    /// The permissions this model reads, in display order.
    let permissions: [AuthorizationPermission]

    /// Where each permission stood at the last refresh, keyed by permission.
    /// Every permission has an entry after the first ``refresh()``.
    private(set) var statuses: [AuthorizationPermission: AuthorizationStatus] = [:]

    /// The authorization seam — the real TCC reads in production.
    @ObservationIgnored private let authorization: any AuthorizationChecking

    /// The engine's event bus, for the `authorization.*` events.
    @ObservationIgnored private let eventBus: EventBus

    /// The task re-reading the permissions on each app activation, while
    /// ``observeActivation(onGranted:)`` runs.
    @ObservationIgnored private var activationTask: Task<Void, Never>?

    /// Creates the model over an authorization seam.
    ///
    /// - Parameters:
    ///   - permissions: The permissions to read, in display order.
    ///   - authorization: Where the permission statuses are read from.
    ///   - eventBus: The engine's event bus.
    init(
        permissions: [AuthorizationPermission],
        authorization: any AuthorizationChecking,
        eventBus: EventBus
    ) {
        self.permissions = permissions
        self.authorization = authorization
        self.eventBus = eventBus
    }

    /// Where a permission stands, or `nil` before the first refresh.
    ///
    /// - Parameter permission: The permission to look up.
    /// - Returns: Its last-read status.
    func status(of permission: AuthorizationPermission) -> AuthorizationStatus? {
        statuses[permission]
    }

    /// Re-reads every permission, reporting each change on the bus.
    ///
    /// The first refresh reports the whole picture once as an
    /// `authorization.status` event; every later refresh reports only what
    /// changed, one `authorization.changed` event per permission, and a
    /// refresh that finds nothing changed is silent.
    ///
    /// - Returns: The permissions that were not `granted` before this
    ///   refresh and are now.
    @discardableResult
    func refresh() -> Set<AuthorizationPermission> {
        let previous = statuses
        var current: [AuthorizationPermission: AuthorizationStatus] = [:]
        for permission in permissions {
            current[permission] = authorization.status(of: permission)
        }
        statuses = current

        if previous.isEmpty {
            eventBus.event(
                "authorization.status",
                domain: .platform,
                params: Dictionary(
                    uniqueKeysWithValues: current.map { ($0.key.rawValue, EventValue.string($0.value.rawValue)) })
            )
            return []
        }

        var newlyGranted: Set<AuthorizationPermission> = []
        for permission in permissions {
            guard let status = current[permission], status != previous[permission] else { continue }
            eventBus.event(
                "authorization.changed",
                domain: .platform,
                params: [
                    "permission": .string(permission.rawValue),
                    "from": .string(previous[permission]?.rawValue ?? "unknown"),
                    "to": .string(status.rawValue),
                ]
            )
            if status == .granted { newlyGranted.insert(permission) }
        }
        return newlyGranted
    }

    /// Asks the system for a permission — prompting the operator when it is
    /// still undecided — then refreshes.
    ///
    /// - Parameter permission: The permission to request.
    /// - Returns: The permissions that newly became `granted`.
    @discardableResult
    func request(_ permission: AuthorizationPermission) async -> Set<AuthorizationPermission> {
        _ = await authorization.request(permission)
        return refresh()
    }

    /// Forgets the system's decision for a permission, then refreshes — the
    /// Permissions pane's Reset button. Reported as an `authorization.reset`
    /// event on success and an `authorization.reset` error naming the reason
    /// otherwise. A reset never stops the camera showing now: it keeps the
    /// access it opened, and macOS asks again the next time a camera opens.
    ///
    /// - Parameter permission: The permission to reset.
    func reset(_ permission: AuthorizationPermission) async {
        do {
            try await authorization.reset(permission)
            eventBus.event(
                "authorization.reset", domain: .platform, params: ["permission": .string(permission.rawValue)])
        } catch {
            eventBus.error(
                "authorization.reset",
                domain: .platform,
                params: [
                    "permission": .string(permission.rawValue),
                    "error": .string((error as? AuthorizationError)?.description ?? String(describing: error)),
                ]
            )
        }
        refresh()
    }

    /// Re-reads the permissions each time the app becomes active, handing any
    /// newly granted ones to the callback. Idempotent — a second call
    /// replaces the first observation.
    ///
    /// - Parameter onGranted: Called with each activation's newly granted
    ///   permissions; never called with an empty set.
    func observeActivation(onGranted: @escaping @MainActor (Set<AuthorizationPermission>) -> Void) {
        activationTask?.cancel()
        let activations = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
        activationTask = Task { [weak self] in
            for await _ in activations {
                guard let self else { return }
                let granted = refresh()
                if !granted.isEmpty { onGranted(granted) }
            }
        }
    }
}

extension AuthorizationPermission {
    /// The System Settings pane where the operator changes this permission,
    /// as the URL `NSWorkspace` opens it by — the only thing a denied
    /// permission's button can do, since the app cannot grant itself
    /// anything.
    var systemSettingsURL: URL? {
        let anchor =
            switch self {
            case .camera: "Privacy_Camera"
            case .microphone: "Privacy_Microphone"
            case .screenRecording: "Privacy_ScreenCapture"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}
