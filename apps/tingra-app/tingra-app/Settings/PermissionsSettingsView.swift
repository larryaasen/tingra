//
//  PermissionsSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraEventBus
import TingraHost

/// The Permissions settings pane: where each system permission the app's
/// inputs depend on stands — Camera, Microphone, Screen Recording — with the
/// one action each state allows.
///
/// A row per permission in the General pane's grouped-form shape: the
/// permission and what Tingra uses it for on the leading edge, its status and
/// its action on the trailing edge. The action is whichever single thing
/// helps: a permission never asked for gets a Request button, which shows the
/// system prompt; a refused one gets a button to the System Settings switch,
/// the only place it can be changed; a granted or policy-restricted one gets
/// none, because nothing the app can do would change it.
///
/// The pane never prompts by being opened — a status read is not a request
/// (``AuthorizationChecking``) — and it never needs a Refresh button: the
/// model re-reads on every app activation, which is how the operator comes
/// back from System Settings, and the pane re-reads on appearing.
struct PermissionsSettingsView: View {
    /// The engine model — for its event bus (every button reports a `tap`)
    /// and its permissions.
    let model: EngineModel

    /// The pane.
    var body: some View {
        Form {
            Section {
                ForEach(AuthorizationPermission.allCases, id: \.self) { permission in
                    PermissionRow(model: model, permission: permission)
                }
            } footer: {
                Text(
                    "macOS grants each permission to this app. Tingra checks again whenever it becomes active, so a change made in System Settings appears here when you return, and an input the change allows starts on its own.",
                    comment: "Permissions settings: footer explaining when the statuses update"
                )
            }
        }
        .formStyle(.grouped)
        .task {
            // Appearing is the other moment the answer could have changed
            // (the pane may open after a grant made while another window of
            // the app stayed active); a refresh is a handful of status reads.
            await model.applyNewlyGranted(model.permissions.refresh())
        }
    }
}

/// One permission's row: name and purpose, status, and the action its state
/// allows.
struct PermissionRow: View {
    /// The engine model — for its event bus and its permissions.
    let model: EngineModel

    /// The permission this row shows.
    let permission: AuthorizationPermission

    /// The row.
    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                StatusLabel(status: status)
                action
            }
        } label: {
            Text(Self.name(of: permission))
            Text(Self.purpose(of: permission))
        }
    }

    /// The permission's last-read status, or `nil` before the first refresh.
    private var status: AuthorizationStatus? {
        model.permissions.status(of: permission)
    }

    /// The one action the status allows, if any.
    @ViewBuilder private var action: some View {
        switch status {
        case .notDetermined:
            Button {
                model.eventBus.tap(
                    "permissionRequest.button", domain: .platform, params: ["permission": .string(permission.rawValue)]
                )
                Task { await model.applyNewlyGranted(await model.permissions.request(permission)) }
            } label: {
                Text("Request…", comment: "Permissions settings: button that shows the system permission prompt")
            }
        case .denied:
            Button {
                model.eventBus.tap(
                    "permissionOpenSettings.button", domain: .platform,
                    params: ["permission": .string(permission.rawValue)]
                )
                if let url = permission.systemSettingsURL {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(
                    "Open System Settings…",
                    comment: "Permissions settings: button that opens the permission's switch in System Settings")
            }
        case .granted, .restricted, nil:
            EmptyView()
        }
    }

    /// A permission's user-facing name.
    ///
    /// - Parameter permission: The permission to name.
    /// - Returns: Its localized name.
    static func name(of permission: AuthorizationPermission) -> LocalizedStringResource {
        switch permission {
        case .camera:
            LocalizedStringResource("Camera", comment: "Permissions settings: the camera permission's name")
        case .microphone:
            LocalizedStringResource("Microphone", comment: "Permissions settings: the microphone permission's name")
        case .screenRecording:
            LocalizedStringResource(
                "Screen Recording", comment: "Permissions settings: the Screen Recording permission's name")
        }
    }

    /// What Tingra uses a permission for, in the row's second line — in the
    /// GLOSSARY's terms, so a permission reads as the inputs it unlocks.
    ///
    /// - Parameter permission: The permission to describe.
    /// - Returns: Its localized purpose.
    static func purpose(of permission: AuthorizationPermission) -> LocalizedStringResource {
        switch permission {
        case .camera:
            LocalizedStringResource(
                "Cameras as inputs, including an iPhone as a Continuity Camera.",
                comment: "Permissions settings: what the camera permission is used for")
        case .microphone:
            LocalizedStringResource(
                "Microphones as inputs.", comment: "Permissions settings: what the microphone permission is used for")
        case .screenRecording:
            LocalizedStringResource(
                "Displays as inputs.", comment: "Permissions settings: what the Screen Recording permission is used for"
            )
        }
    }
}

/// A permission's status as a colored symbol and a word, the pair every
/// status list on the Mac uses so the color is never the only signal.
struct StatusLabel: View {
    /// The status to show, or `nil` before the first refresh.
    let status: AuthorizationStatus?

    /// The label.
    var body: some View {
        Label {
            Text(Self.name(of: status))
        } icon: {
            Image(systemName: Self.systemImage(of: status))
                .foregroundStyle(Self.color(of: status))
        }
        .accessibilityElement(children: .combine)
    }

    /// A status's user-facing word.
    ///
    /// - Parameter status: The status to name, or `nil` before the first
    ///   refresh.
    /// - Returns: Its localized name.
    static func name(of status: AuthorizationStatus?) -> LocalizedStringResource {
        switch status {
        case .granted:
            LocalizedStringResource("Granted", comment: "Permissions settings: status of a permission macOS allows")
        case .denied:
            LocalizedStringResource("Denied", comment: "Permissions settings: status of a permission macOS refuses")
        case .notDetermined:
            LocalizedStringResource(
                "Not Requested", comment: "Permissions settings: status of a permission the app has never asked for")
        case .restricted:
            LocalizedStringResource(
                "Restricted", comment: "Permissions settings: status of a permission a policy forbids")
        case nil:
            LocalizedStringResource("Checking…", comment: "Permissions settings: status before the first read")
        }
    }

    /// The SF Symbol for a status.
    ///
    /// - Parameter status: The status, or `nil` before the first refresh.
    /// - Returns: The symbol name.
    static func systemImage(of status: AuthorizationStatus?) -> String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "questionmark.circle.fill"
        case .restricted: "lock.circle.fill"
        case nil: "circle.dotted"
        }
    }

    /// The symbol's color for a status: the system's semantic colors, so the
    /// pane reads the same way the Mac's other status lists do.
    ///
    /// - Parameter status: The status, or `nil` before the first refresh.
    /// - Returns: The color.
    static func color(of status: AuthorizationStatus?) -> Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        case .restricted, nil: .secondary
        }
    }
}
