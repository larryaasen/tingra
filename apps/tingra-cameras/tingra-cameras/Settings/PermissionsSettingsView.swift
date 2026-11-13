//
//  PermissionsSettingsView.swift
//  tingra-cameras
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraEventBus
import TingraHost

/// The Permissions settings pane: where the camera permission stands, with
/// the one action its state allows — the main Tingra app's pane, with the
/// one permission this app needs.
///
/// A permission never asked for gets a Request button, which shows the
/// system prompt; a refused one gets a button to the System Settings switch,
/// the only place it can be changed; a granted or policy-restricted one gets
/// none. **Reset** asks the system to forget a decision, so macOS asks again
/// the next time a camera opens; it is disabled while there is no decision to
/// forget.
///
/// The pane never prompts by being opened — a status read is not a request —
/// and needs no Refresh button: the model re-reads on every app activation,
/// which is how the operator comes back from System Settings, and the pane
/// re-reads on appearing.
struct PermissionsSettingsView: View {
    /// The shared hardware model — for its event bus and its permissions.
    @Environment(HardwareModel.self) private var model

    /// The pane.
    var body: some View {
        Form {
            Section {
                ForEach(model.permissions.permissions, id: \.self) { permission in
                    PermissionRow(permission: permission)
                }
            } footer: {
                Text(
                    "macOS grants each permission to this app. Tingra Cameras checks again whenever it becomes active, so a change made in System Settings appears here when you return, and the preview starts on its own. Reset forgets a decision, so macOS asks again the next time a camera opens.",
                    comment: "Permissions settings: footer explaining when the statuses update and what Reset does"
                )
            }
        }
        .formStyle(.grouped)
        .task {
            // Appearing is the other moment the answer could have changed;
            // a refresh is a single status read.
            model.applyNewlyGranted(model.permissions.refresh())
        }
    }
}

/// One permission's row: name and purpose, status, and the action its state
/// allows.
struct PermissionRow: View {
    /// The shared hardware model — for its event bus and its permissions.
    @Environment(HardwareModel.self) private var model

    /// The permission this row shows.
    let permission: AuthorizationPermission

    /// The row.
    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                StatusLabel(status: status)
                action
                resetButton
            }
        } label: {
            Text(Self.name(of: permission))
            Text(Self.purpose(of: permission))
        }
    }

    /// The Reset button: forgets the system's decision for this permission.
    /// Disabled while there is none to forget.
    private var resetButton: some View {
        Button {
            model.recordTap("permissionReset.button", params: ["permission": .string(permission.rawValue)])
            Task { await model.permissions.reset(permission) }
        } label: {
            Text("Reset", comment: "Permissions settings: button that forgets the system's decision for a permission")
        }
        .disabled(status != .granted && status != .denied)
        .help(
            Text(
                "Forget this permission, so macOS asks again the next time a camera opens",
                comment: "Tooltip on a permission's Reset button"
            )
        )
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
                model.recordTap("permissionRequest.button", params: ["permission": .string(permission.rawValue)])
                Task { model.applyNewlyGranted(await model.permissions.request(permission)) }
            } label: {
                Text("Request…", comment: "Permissions settings: button that shows the system permission prompt")
            }
        case .denied, .unknown:
            Button {
                model.recordTap("permissionOpenSettings.button", params: ["permission": .string(permission.rawValue)])
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
            // The compact window's camera picker label shares this word and
            // its comment, so the catalog keeps one entry for both.
            LocalizedStringResource(
                "Camera",
                comment:
                    "Permissions settings: the camera permission's name; also the compact window's camera picker label"
            )
        case .microphone:
            LocalizedStringResource("Microphone", comment: "Permissions settings: the microphone permission's name")
        case .screenRecording:
            LocalizedStringResource(
                "Screen Recording", comment: "Permissions settings: the Screen Recording permission's name")
        case .systemAudioRecording:
            LocalizedStringResource(
                "System Audio Recording",
                comment: "Permissions settings: the System Audio Recording permission's name")
        }
    }

    /// What Tingra Cameras uses a permission for, in the row's second line.
    /// Only the camera is ever listed; the others are named so the switch
    /// stays exhaustive over the host's permissions.
    ///
    /// - Parameter permission: The permission to describe.
    /// - Returns: Its localized purpose.
    static func purpose(of permission: AuthorizationPermission) -> LocalizedStringResource {
        switch permission {
        case .camera:
            LocalizedStringResource(
                "The selected camera's live preview.",
                comment: "Permissions settings: what the camera permission is used for")
        case .microphone:
            LocalizedStringResource(
                "Not used by Tingra Cameras.",
                comment: "Permissions settings: purpose of a permission the app never asks for")
        case .screenRecording:
            LocalizedStringResource(
                "Not used by Tingra Cameras.",
                comment: "Permissions settings: purpose of a permission the app never asks for")
        case .systemAudioRecording:
            LocalizedStringResource(
                "Not used by Tingra Cameras.",
                comment: "Permissions settings: purpose of a permission the app never asks for")
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
        case .unknown:
            LocalizedStringResource(
                "Asked When First Used",
                comment: "Permissions settings: status of a permission macOS offers no way to check in advance")
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
        case .unknown: "questionmark.circle"
        case nil: "circle.dotted"
        }
    }

    /// The symbol's color for a status: the system's semantic colors.
    ///
    /// - Parameter status: The status, or `nil` before the first refresh.
    /// - Returns: The color.
    static func color(of status: AuthorizationStatus?) -> Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        case .restricted, .unknown, nil: .secondary
        }
    }
}
