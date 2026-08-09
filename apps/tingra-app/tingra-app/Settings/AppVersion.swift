//
//  AppVersion.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-08-08.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation

/// The app's version as the About settings tab prints it: the marketing
/// version and the build, read from the bundle rather than written down
/// anywhere in code.
///
/// Its own small value type rather than two `Bundle` lookups inside the view,
/// for the reason every pure type in this app has one: the assembly rule —
/// when the build is worth printing and when it is noise, and what to do with
/// a bundle that names neither — is a decision, and a decision is testable
/// where a view is not.
///
/// Every field is optional and nothing is invented. A bundle missing its
/// version keys is a build-configuration defect, and an About pane that
/// confidently printed `1.0` for it would hide exactly the thing worth
/// noticing.
struct AppVersion: Equatable, Sendable {
    /// `CFBundleShortVersionString` — the version a user quotes ("1.0").
    let shortVersion: String?

    /// `CFBundleVersion` — the build number behind it ("1", "402").
    let build: String?

    /// Creates a version from its two parts.
    ///
    /// - Parameters:
    ///   - shortVersion: The marketing version, or nil when the bundle names
    ///     none.
    ///   - build: The build number, or nil when the bundle names none.
    init(shortVersion: String?, build: String?) {
        self.shortVersion = shortVersion
        self.build = build
    }

    /// Reads the version from a bundle.
    ///
    /// - Parameter bundle: The bundle to read (the app's own by default —
    ///   `Bundle.module` does not exist in an app target).
    init(bundle: Bundle = .main) {
        self.init(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// The version as the About tab prints it — `1.0 (12)` — or nil when the
    /// bundle names no version at all.
    ///
    /// The build is parenthesized after the version, the Apple convention, and
    /// dropped when it repeats the version or is absent: `1.0 (1.0)` says
    /// nothing twice.
    var displayString: String? {
        switch (shortVersion, build) {
        case (let version?, let build?) where version != build: "\(version) (\(build))"
        case (let version?, _): version
        case (nil, let build?): build
        case (nil, nil): nil
        }
    }
}
