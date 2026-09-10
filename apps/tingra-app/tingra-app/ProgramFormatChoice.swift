//
//  ProgramFormatChoice.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition

/// The named program sizes the **Program** menu's Size submenu offers
/// (ARCHITECTURE.md, "The program format as a project setting"): SD through
/// 4K UHD, with one portrait entry for the vertical platforms. Every entry
/// is even on both axes, which 4:2:0 delivery requires. 8K is deliberately
/// absent — reachable through the Custom Size… sheet, but not advertised
/// until the compositor has been measured at that size.
enum ProgramSize: String, CaseIterable, Identifiable, Sendable {
    /// Standard definition, 4:3 — 640×480.
    case sd
    /// 480p, 16:9 — 854×480.
    case p480
    /// 720p — 1280×720.
    case p720
    /// 1080p — 1920×1080, the default.
    case p1080
    /// Portrait 1080p — 1080×1920, for the vertical platforms.
    case vertical1080
    /// 1440p — 2560×1440.
    case p1440
    /// 4K UHD — 3840×2160.
    case uhd4K

    var id: String { rawValue }

    /// The size's width in pixels.
    var width: Int {
        switch self {
        case .sd: 640
        case .p480: 854
        case .p720: 1280
        case .p1080: 1920
        case .vertical1080: 1080
        case .p1440: 2560
        case .uhd4K: 3840
        }
    }

    /// The size's height in pixels.
    var height: Int {
        switch self {
        case .sd: 480
        case .p480: 480
        case .p720: 720
        case .p1080: 1080
        case .vertical1080: 1920
        case .p1440: 1440
        case .uhd4K: 2160
        }
    }

    /// The menu item's title: the common name with the pixel size beside
    /// it, so an operator who knows one finds the other.
    var title: String {
        switch self {
        case .sd: String(localized: "SD (640×480)", comment: "Program size menu item: standard definition, 4:3")
        case .p480: String(localized: "480p (854×480)", comment: "Program size menu item: 480p, 16:9")
        case .p720: String(localized: "720p (1280×720)", comment: "Program size menu item: 720p")
        case .p1080: String(localized: "1080p (1920×1080)", comment: "Program size menu item: 1080p, the default")
        case .vertical1080:
            String(localized: "Vertical (1080×1920)", comment: "Program size menu item: portrait 1080p")
        case .p1440: String(localized: "1440p (2560×1440)", comment: "Program size menu item: 1440p")
        case .uhd4K: String(localized: "4K (3840×2160)", comment: "Program size menu item: 4K UHD")
        }
    }

    /// The named size whose dimensions a format has, or `nil` for a custom
    /// size — what checks the Size submenu's items.
    ///
    /// - Parameter format: The program format to look up.
    /// - Returns: The matching named size, if any.
    static func named(matching format: ProgramFormat) -> ProgramSize? {
        allCases.first { $0.width == format.width && $0.height == format.height }
    }

    /// This size at a frame rate.
    ///
    /// - Parameter frameRate: The frame rate to pair the size with.
    /// - Returns: The program format.
    func format(at frameRate: Int) -> ProgramFormat {
        ProgramFormat(width: width, height: height, frameRate: frameRate)
    }
}

/// What can be wrong with a custom program format the operator typed —
/// each with the message the Custom Size… sheet shows in its place.
enum ProgramFormatProblem: Equatable, Sendable {
    /// A dimension is odd; 4:2:0 delivery needs even dimensions.
    case oddDimension
    /// A dimension is below the smallest size the compositor will render.
    case tooSmall
    /// The frame rate is outside 1…240.
    case badFrameRate

    /// The message shown beneath the fields.
    var message: String {
        switch self {
        case .oddDimension:
            String(
                localized: "The program size must be even — 4:2:0 delivery requires it.",
                comment: "Custom program size sheet: a width or height is odd")
        case .tooSmall:
            String(
                localized: "The program size must be at least 16 by 16 pixels.",
                comment: "Custom program size sheet: a width or height is too small")
        case .badFrameRate:
            String(
                localized: "The frame rate must be between 1 and 240.",
                comment: "Custom program size sheet: the frame rate is out of range")
        }
    }
}

/// The pure rules behind the Program menu and its sheet — what the menu
/// lists, how a format reads on the status bar, when a change is refused,
/// and what makes a typed format invalid — kept apart from the views so
/// they are testable without one.
enum ProgramFormatChoice {
    /// The frame rates the Frame Rate submenu offers: the film, PAL, and NTSC
    /// families' whole-number rates. A custom rate is typed in the sheet.
    static let frameRates = [24, 25, 30, 50, 60]

    /// The smallest width or height a custom size may have.
    static let minimumDimension = 16

    /// The highest frame rate a custom format may ask for.
    static let maximumFrameRate = 240

    /// The format as the status bar reads it — pixel size and rate, verbatim
    /// in every language, like the delivery counters beside it.
    ///
    /// - Parameter format: The program format.
    /// - Returns: For example "1920×1080 · 30 fps".
    static func label(for format: ProgramFormat) -> String {
        "\(format.width)×\(format.height) · \(format.frameRate) fps"
    }

    /// Why a format change is refused right now, or `nil` when it is
    /// allowed: the sinks' compression sessions are open at a size while the
    /// program is streaming or recording, so the format is a session-start
    /// setting there, as it is for the CLI.
    ///
    /// - Parameters:
    ///   - isStreaming: Whether a stream session is starting, live, or
    ///     reconnecting.
    ///   - isRecording: Whether a recording is starting or writing.
    /// - Returns: `"streaming"` or `"recording"` — the `reason` the refusal's
    ///   error event carries — or `nil`.
    static func refusal(isStreaming: Bool, isRecording: Bool) -> String? {
        if isStreaming { return "streaming" }
        if isRecording { return "recording" }
        return nil
    }

    /// What is wrong with a typed format, or `nil` when it is valid. The
    /// size rules are the CLI's own for `--resolution`: even, and positive.
    ///
    /// - Parameters:
    ///   - width: The typed width.
    ///   - height: The typed height.
    ///   - frameRate: The typed frame rate.
    /// - Returns: The first problem found, or `nil`.
    static func problem(width: Int, height: Int, frameRate: Int) -> ProgramFormatProblem? {
        if width < minimumDimension || height < minimumDimension { return .tooSmall }
        if !width.isMultiple(of: 2) || !height.isMultiple(of: 2) { return .oddDimension }
        if frameRate < 1 || frameRate > maximumFrameRate { return .badFrameRate }
        return nil
    }
}
