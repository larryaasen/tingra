//
//  AboutSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI

/// The About settings pane: the app's version, and how long it has been
/// running.
///
/// The icon and the name beside it are not decoration — they are what makes a
/// version number mean something when an operator is asked which build they
/// are running, and they cost nothing: both come from the bundle, so neither
/// can drift from what actually shipped.
///
/// The **uptime** section (2026-09-26) answers "how long has this been
/// open?" — the question before a long show, and after one that misbehaved.
/// It re-renders on the uptime's own minute boundaries, counted from the
/// launch, through a `TimelineView`: elapsed time is the one value with no
/// event to wait for, so the schedule is the clock itself, and it runs only
/// while the pane is on screen.
struct AboutSettingsView: View {
    /// How long the app has been running.
    let uptime: AppUptime

    /// The version read from the app's bundle.
    private let version = AppVersion()

    /// The locale the uptime's units are written in.
    @Environment(\.locale) private var locale

    /// The size the app icon is drawn at.
    private static let iconSize: CGFloat = 64

    /// The pane.
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    icon

                    VStack(alignment: .leading, spacing: 4) {
                        // The product name, never localized — Tingra is
                        // Tingra in every language (GLOSSARY.md).
                        Text(verbatim: "Tingra")
                            .font(.title2.weight(.semibold))

                        versionLabel
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent {
                    TimelineView(.periodic(from: uptime.launchDate, by: 60)) { context in
                        Text(verbatim: uptime.text(at: context.date, locale: locale))
                            .monospacedDigit()
                    }
                } label: {
                    Text(
                        "Uptime", comment: "About settings: label of the row showing how long the app has been running")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The app's own icon, taken from the running application so it always
    /// matches the bundle.
    @ViewBuilder private var icon: some View {
        if let image = NSApplication.shared.applicationIconImage {
            Image(nsImage: image)
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
        }
    }

    /// The version line — or, for a bundle that names no version at all, a
    /// line saying so rather than a confident wrong number (see
    /// ``AppVersion``).
    private var versionLabel: Text {
        if let displayString = version.displayString {
            Text("Version \(displayString)", comment: "About settings: the app's version and build number")
        } else {
            Text("Version unavailable", comment: "About settings: shown when the bundle names no version")
        }
    }
}
