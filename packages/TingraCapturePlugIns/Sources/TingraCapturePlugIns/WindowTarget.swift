//
//  WindowTarget.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-10-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The window a window input captures, as it can be remembered: the
/// application that owns it and the title it had when the operator chose it.
///
/// A window has **no stable identifier**. A display's UUID survives reboots;
/// a window's `CGWindowID` dies with the window, and WindowServer hands the
/// same numbers out again after a restart. So what a project saves is this
/// description, and each capture start finds the window that fits it now
/// (``WindowMatching``) — which can miss, and says so, when the application
/// has retitled the window or holds several that fit (ARCHITECTURE.md,
/// "Window capture").
public struct WindowTarget: Sendable, Hashable {
    /// The owning application's bundle identifier, e.g. `com.apple.Keynote`.
    public let bundleIdentifier: String

    /// The owning application's user-facing name, e.g. "Keynote".
    public let applicationName: String

    /// The window's title when it was chosen.
    public let title: String

    /// Creates a target.
    ///
    /// - Parameters:
    ///   - bundleIdentifier: The owning application's bundle identifier.
    ///   - applicationName: The owning application's user-facing name.
    ///   - title: The window's title.
    public init(bundleIdentifier: String, applicationName: String, title: String) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
    }

    /// The user-facing name of an input capturing this window: the
    /// application, then the window, so a list of them sorts by application.
    /// A window titled as its application (or not at all) reads as the
    /// application alone, never as the name twice.
    public var name: String {
        guard !title.isEmpty, title != applicationName else { return applicationName }
        return "\(applicationName) — \(title)"
    }
}

/// One window that can be captured right now, as the picker lists it: the
/// framework-free reduction of a ScreenCaptureKit window that the rest of
/// the plug-in, its tests, and the app work with — the window counterpart to
/// ``CaptureDevice``.
///
/// Unlike a display, a window can only be listed with Screen Recording
/// access: macOS withholds other applications' window titles without it.
public struct CaptureWindow: Sendable, Equatable, Identifiable {
    /// The window's `CGWindowID` — exact for as long as the window lives,
    /// and meaningless after, so it identifies a window within one run and
    /// is never saved.
    public let id: UInt32

    /// The description a project saves for this window.
    public let target: WindowTarget

    /// The window's width in points.
    public let width: Double

    /// The window's height in points.
    public let height: Double

    /// Whether the window is on screen now: not minimized, not hidden, and
    /// on a Space being shown.
    public let isOnScreen: Bool

    /// Creates a window record.
    ///
    /// - Parameters:
    ///   - id: The window's `CGWindowID`.
    ///   - target: The owning application and the window's title.
    ///   - width: The window's width in points.
    ///   - height: The window's height in points.
    ///   - isOnScreen: Whether the window is on screen now.
    public init(id: UInt32, target: WindowTarget, width: Double, height: Double, isOnScreen: Bool) {
        self.id = id
        self.target = target
        self.width = width
        self.height = height
        self.isOnScreen = isOnScreen
    }
}

/// The rules that turn the windows open right now into the picker's list and
/// into the one window a saved ``WindowTarget`` means — pure, so they are
/// unit-tested without ScreenCaptureKit or the Screen Recording prompt.
enum WindowMatching {
    /// Finds the window a target means among the windows open now, or nil
    /// when none can be named with confidence.
    ///
    /// In order:
    /// 1. **The same window**, by the identifier it had the last time this
    ///    run captured it — exact, and the only rule that survives the
    ///    application retitling the window (a browser does on every page).
    /// 2. **The application's window with the saved title.** When several
    ///    carry it, one on screen wins, then the oldest.
    /// 3. **The application's only window on screen**, when none carries the
    ///    title — a document renamed since the project was saved.
    ///
    /// Anything else is nil rather than a guess: the wrong window on program
    /// is a worse outcome than a layer that stays empty until the operator
    /// chooses again.
    ///
    /// - Parameters:
    ///   - target: The saved description.
    ///   - lastWindowID: The identifier the window had when this run last
    ///     captured it, or nil when it has not yet.
    ///   - windows: Every capturable window open now.
    /// - Returns: The window, or nil.
    static func resolve(
        _ target: WindowTarget,
        lastWindowID: UInt32?,
        among windows: [CaptureWindow]
    ) -> CaptureWindow? {
        let owned = windows.filter { $0.target.bundleIdentifier == target.bundleIdentifier }
        if let lastWindowID, let same = owned.first(where: { $0.id == lastWindowID }) {
            return same
        }
        let titled = owned.filter { $0.target.title == target.title }.sorted { $0.id < $1.id }
        if let match = titled.first(where: \.isOnScreen) ?? titled.first {
            return match
        }
        let onScreen = owned.filter(\.isOnScreen)
        return onScreen.count == 1 ? onScreen.first : nil
    }

    /// The windows the picker offers: those on screen, by application and
    /// then title, in a stable order so the list does not reshuffle between
    /// two openings.
    ///
    /// On screen only, because a window list read without that filter is
    /// mostly windows nobody can see — panels an application keeps built but
    /// hidden — and the operator can only recognize what is in front of
    /// them. A saved target is still resolved against every window
    /// (``resolve(_:lastWindowID:among:)``), so one on another Space is
    /// found again.
    ///
    /// - Parameter windows: Every capturable window open now.
    /// - Returns: The picker's rows.
    static func pickerWindows(from windows: [CaptureWindow]) -> [CaptureWindow] {
        windows.filter(\.isOnScreen).sorted { first, second in
            let byApplication = first.target.applicationName.localizedStandardCompare(second.target.applicationName)
            if byApplication != .orderedSame { return byApplication == .orderedAscending }
            let byTitle = first.target.title.localizedStandardCompare(second.target.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return first.id < second.id
        }
    }
}
