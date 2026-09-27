//
//  AppUptime.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// How long the app has been running, as the About settings pane prints it:
/// "4 min", "43 min", "1 hour 43 min", "29 hours 1 min", "2 hours".
///
/// Its own small value type for the same reason as ``AppVersion``: the
/// wording — whole minutes, hours spelled out and minutes abbreviated, no
/// "0 min" tail on a round hour, hours never rolled up into days — is a
/// decision, and a decision is testable where a view is not.
///
/// **The launch is recorded by the app, not read from the system.**
/// `NSRunningApplication.launchDate` is nil for a process LaunchServices did
/// not start, which is how `scripts/run-app.sh` runs the app, so ``TingraApp``
/// records the moment it is created instead — the app's own launch, to within
/// the time its first line of code takes to run.
///
/// Wall-clock time throughout, so a Mac that slept overnight reports the
/// night: uptime is how long this Tingra has been open, not how long the CPU
/// was awake.
struct AppUptime: Equatable, Sendable {
    /// When the app launched.
    let launchDate: Date

    /// Creates an uptime counted from a launch.
    ///
    /// - Parameter launchDate: When the app launched (default: now, which is
    ///   what the app passes as it is created).
    init(launchDate: Date = .now) {
        self.launchDate = launchDate
    }

    /// How long the app had been running at a moment — never negative, so a
    /// clock set back after launch reads as a fresh start rather than a
    /// countdown.
    ///
    /// - Parameter date: The moment to measure at.
    /// - Returns: The running time.
    func elapsed(at date: Date) -> Duration {
        .seconds(max(0, date.timeIntervalSince(launchDate)))
    }

    /// The uptime at a moment, worded for the About pane.
    ///
    /// - Parameters:
    ///   - date: The moment to measure at.
    ///   - locale: The locale the units are written in.
    /// - Returns: The uptime, e.g. "1 hour 43 min".
    func text(at date: Date, locale: Locale) -> String {
        Self.text(for: elapsed(at: date), locale: locale)
    }

    /// Words a running time in whole minutes: minutes alone under an hour
    /// ("4 min", including "0 min" in the first minute), otherwise hours
    /// spelled out and then minutes ("1 hour 43 min"), with the minutes left
    /// off a round hour ("2 hours"). Hours keep counting past a day — "29
    /// hours" says how long a show has been open more plainly than "1 day 5
    /// hours".
    ///
    /// Each unit is written by `Duration`'s own format style, so plurals and
    /// abbreviations follow the locale; only the joining of the two is
    /// Tingra's, and it is a catalog string so a language can reorder it.
    ///
    /// - Parameters:
    ///   - elapsed: The running time; a negative one reads as zero.
    ///   - locale: The locale the units are written in.
    /// - Returns: The worded uptime.
    static func text(for elapsed: Duration, locale: Locale) -> String {
        let totalMinutes = max(0, elapsed.components.seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let minutesText = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.minutes], width: .abbreviated).locale(locale))
        guard hours > 0 else { return minutesText }
        let hoursText = Duration.seconds(hours * 3600)
            .formatted(.units(allowed: [.hours], width: .wide).locale(locale))
        guard minutes > 0 else { return hoursText }
        return String(
            localized: "\(hoursText) \(minutesText)",
            comment: "About settings: an uptime of hours then minutes, e.g. “1 hour” then “43 min”"
        )
    }
}
