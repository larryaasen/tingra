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

/// The About settings pane: the app's version.
///
/// The icon and the name beside it are not decoration — they are what makes a
/// version number mean something when an operator is asked which build they
/// are running, and they cost nothing: both come from the bundle, so neither
/// can drift from what actually shipped.
struct AboutSettingsView: View {
    /// The version read from the app's bundle.
    private let version = AppVersion()

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
