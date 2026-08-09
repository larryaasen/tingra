//
//  GeneralSettingsView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// The General settings pane: the app's Appearance, System / Light / Dark.
///
/// A grouped `Form` with the control on the trailing edge of a labeled row —
/// the shape every settings pane on macOS 26 has, and the one that keeps a
/// second and third setting from needing a new layout.
struct GeneralSettingsView: View {
    /// The engine model — here for its event bus, so a change is reported as
    /// a `tap`.
    let model: EngineModel

    /// The app's appearance.
    @Bindable var appearance: AppearanceModel

    /// The pane.
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    AppearancePicker(selection: appearanceSelection)
                } label: {
                    Text("Appearance", comment: "General settings: label of the light/dark appearance control")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The appearance binding, reporting its own `tap` before the change
    /// lands.
    ///
    /// The `tap` rides the binding rather than `.onChange` for the reason
    /// ``Binding/reportingTap(to:_:domain:params:)`` exists: a setter runs
    /// only when the operator works the control, so the appearance the model
    /// installs at launch never records a tap nobody made.
    private var appearanceSelection: Binding<AppearanceMode> {
        $appearance.mode.reportingTap(
            to: model.eventBus,
            "appearance.picker",
            domain: .platform,
            params: { ["mode": .string($0.rawValue)] }
        )
    }
}

/// The Appearance control: three thumbnails, one per ``AppearanceMode``, the
/// selected one ringed — the same control System Settings and Xcode use.
///
/// Thumbnails rather than a segmented picker of three words, because the
/// setting is about *how things look*: a small picture of the result says it
/// in a glance, and the System option in particular is far easier to read as
/// a split light/dark tile than as the word "System".
struct AppearancePicker: View {
    /// The selected mode.
    @Binding var selection: AppearanceMode

    /// One thumbnail per mode, in the System / Light / Dark order every Apple
    /// appearance control uses.
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    AppearanceSwatch(mode: mode, isSelected: mode == selection)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.name(of: mode))
                .accessibilityAddTraits(mode == selection ? [.isSelected] : [])
            }
        }
    }

    /// A mode's user-facing name, shown under its thumbnail and read by
    /// VoiceOver.
    ///
    /// - Parameter mode: The mode to name.
    /// - Returns: The localized name.
    static func name(of mode: AppearanceMode) -> Text {
        switch mode {
        case .system: Text("System", comment: "Appearance option: follow the system's light or dark setting")
        case .light: Text("Light", comment: "Appearance option: always draw the app light")
        case .dark: Text("Dark", comment: "Appearance option: always draw the app dark")
        }
    }
}

/// One thumbnail of the Appearance control: a miniature window over a
/// miniature desktop, in the mode it stands for, with the mode's name beneath
/// it.
struct AppearanceSwatch: View {
    /// The mode this thumbnail stands for.
    let mode: AppearanceMode

    /// Whether it is the selected one — ringed and named in the accent color
    /// if so.
    let isSelected: Bool

    /// The thumbnail's size, close enough to the system's own that the
    /// control reads as the same control.
    private static let size = CGSize(width: 76, height: 48)

    /// The thumbnail's corner radius.
    private static let cornerRadius: CGFloat = 6

    /// The thumbnail over its name.
    var body: some View {
        VStack(spacing: 4) {
            picture
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(.rect(cornerRadius: Self.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                            lineWidth: isSelected ? 3 : 1
                        )
                }

            AppearancePicker.name(of: mode)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
    }

    /// The miniature desktop itself.
    ///
    /// ``AppearanceMode/system`` draws **both** — the light desktop with the
    /// dark one masked over its trailing half — rather than a third artwork,
    /// so the split tile can never drift from the two it is a split of. The
    /// mask is a two-`Color` `HStack` rather than measured geometry: two
    /// flexible colors split the width evenly on their own.
    @ViewBuilder private var picture: some View {
        switch mode {
        case .system:
            ZStack {
                AppearanceMiniDesktop(isDark: false)
                AppearanceMiniDesktop(isDark: true)
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear
                            Color.black
                        }
                    }
            }
        case .light:
            AppearanceMiniDesktop(isDark: false)
        case .dark:
            AppearanceMiniDesktop(isDark: true)
        }
    }
}

/// The miniature desktop drawn inside an ``AppearanceSwatch``: a wallpaper
/// with one window on it, in light or dark.
///
/// Drawn rather than shipped as an asset so it follows the accent color and
/// needs no light/dark image pair of its own — and so the System swatch can
/// composite two of them.
struct AppearanceMiniDesktop: View {
    /// Whether to draw the dark appearance.
    let isDark: Bool

    /// The wallpaper behind the miniature window.
    private var desktop: Color {
        isDark ? Color(white: 0.16) : Color(white: 0.87)
    }

    /// The miniature window's fill.
    private var window: Color {
        isDark ? Color(white: 0.28) : .white
    }

    /// The window's title bar, a shade off the window itself so the two read
    /// as separate.
    private var titleBar: Color {
        isDark ? Color(white: 0.36) : Color(white: 0.94)
    }

    /// The wallpaper with a window over it.
    var body: some View {
        ZStack {
            desktop

            VStack(spacing: 0) {
                titleBar
                    .frame(height: 8)
                    .overlay(alignment: .leading) { trafficLights.padding(.leading, 3) }
                window
            }
            .clipShape(.rect(cornerRadius: 3))
            .padding(EdgeInsets(top: 9, leading: 10, bottom: 5, trailing: 6))
        }
    }

    /// The window's three close/minimize/zoom dots — the detail that makes a
    /// rounded rectangle read as a window at this size.
    private var trafficLights: some View {
        HStack(spacing: 2) {
            ForEach([Color.red, .yellow, .green], id: \.self) { color in
                Circle()
                    .fill(color)
                    .frame(width: 3, height: 3)
            }
        }
    }
}
