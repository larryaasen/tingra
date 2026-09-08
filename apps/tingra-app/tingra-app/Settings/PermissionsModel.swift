//
//  PermissionsModel.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import Observation
import TingraEventBus
import TingraHost

/// Where each of the app's system permissions stands — the model behind the
/// Permissions settings pane, and the engine's own record of what TCC
/// currently allows.
///
/// **Refreshed on events, never polled** (CLAUDE.md). macOS offers no
/// notification when a TCC grant changes, but it does not need one: a grant
/// changes in exactly one place, System Settings, and coming back from there
/// is an app activation. So the model re-reads every permission on
/// `didBecomeActive`, and on the settings pane appearing — the two moments
/// the answer could have changed since it was last read. Each change is
/// reported on the bus, and the set of permissions that newly became
/// ``AuthorizationStatus/granted`` is handed back so the engine can start the
/// inputs the grant unblocks without being asked (observed 2026-09-06: with
/// Screen Recording granted mid-session, the display inputs sat denied until
/// the next reconfigure pass happened along).
///
/// The `@Observable` rule: `@MainActor`, owned by the ``EngineModel``, read by
/// the pane.
@MainActor
@Observable
final class PermissionsModel {
    /// Where each permission stood at the last refresh, keyed by permission.
    /// Every permission has an entry after the first ``refresh()``.
    private(set) var statuses: [AuthorizationPermission: AuthorizationStatus] = [:]

    /// The authorization seam — the real TCC reads in production, a scripted
    /// answer in tests.
    @ObservationIgnored private let authorization: any AuthorizationChecking

    /// The host's event bus, for the `authorization.*` events.
    @ObservationIgnored private let eventBus: EventBus

    /// The task re-reading the permissions on each app activation, while
    /// ``observeActivation(onGranted:)`` runs.
    @ObservationIgnored private var activationTask: Task<Void, Never>?

    /// Creates the model over an authorization seam.
    ///
    /// - Parameters:
    ///   - authorization: Where the permission statuses are read from.
    ///   - eventBus: The host's event bus.
    init(authorization: any AuthorizationChecking, eventBus: EventBus) {
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
    /// `authorization.status` event — the line a session log needs to say
    /// what TCC allowed at launch. Every later refresh reports only what
    /// changed, one `authorization.changed` event per permission; a refresh
    /// that finds nothing changed is silent, so an app activated a hundred
    /// times leaves no trace on the bus.
    ///
    /// - Returns: The permissions that were not `granted` before this
    ///   refresh and are now — the set whose inputs can start.
    @discardableResult
    func refresh() -> Set<AuthorizationPermission> {
        let previous = statuses
        var current: [AuthorizationPermission: AuthorizationStatus] = [:]
        for permission in AuthorizationPermission.allCases {
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
        for permission in AuthorizationPermission.allCases {
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
    /// - Returns: The permissions that newly became `granted`, as
    ///   ``refresh()`` reports them.
    @discardableResult
    func request(_ permission: AuthorizationPermission) async -> Set<AuthorizationPermission> {
        _ = await authorization.request(permission)
        return refresh()
    }

    /// Forgets the system's decision for a permission, then refreshes — the
    /// Permissions pane's Reset button.
    ///
    /// Reported as an `authorization.reset` event on success and an
    /// `authorization.reset` error naming the reason otherwise; the refresh
    /// that follows either way reports what the system now says, which is
    /// the only status the pane shows. A reset never starts or stops an
    /// input: a running one keeps the access it opened, and macOS asks again
    /// the next time the permission is needed.
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
    /// newly granted ones to the callback.
    ///
    /// The app becoming active is the event a TCC change rides on: the
    /// operator grants in System Settings and returns. Idempotent — a second
    /// call replaces the first observation.
    ///
    /// - Parameter onGranted: Called with each activation's newly granted
    ///   permissions; never called with an empty set.
    func observeActivation(onGranted: @escaping @MainActor (Set<AuthorizationPermission>) async -> Void) {
        activationTask?.cancel()
        let activations = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)
        activationTask = Task { [weak self] in
            for await _ in activations {
                guard let self else { return }
                let granted = refresh()
                if !granted.isEmpty { await onGranted(granted) }
            }
        }
    }

    /// Stops re-reading on activation.
    func stopObservingActivation() {
        activationTask?.cancel()
        activationTask = nil
    }
}

extension AuthorizationPermission {
    /// The System Settings pane where the operator changes this permission,
    /// as the URL `NSWorkspace` opens it by.
    ///
    /// The `x-apple.systempreferences:` scheme with the Privacy & Security
    /// anchors is what System Settings has honored since it replaced System
    /// Preferences, and it is the whole of what a denied permission's button
    /// can do: the app cannot grant itself anything, only take the operator
    /// to the switch.
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
