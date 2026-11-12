//
//  TimeTextStyle.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import TingraPlugInKit

/// Where on the frame a time generator draws its text. The raw value is the
/// number a ``Parameter/Kind/choice`` payload carries, so it is part of the
/// project contract and never renumbered.
enum TimeTextPosition: Int, CaseIterable, Sendable {
    /// The middle of the frame.
    case center = 0

    /// The top left corner.
    case topLeft = 1

    /// The middle of the top edge.
    case top = 2

    /// The top right corner.
    case topRight = 3

    /// The bottom left corner.
    case bottomLeft = 4

    /// The middle of the bottom edge.
    case bottom = 5

    /// The bottom right corner.
    case bottomRight = 6

    /// The short user-facing name a host's pop-up menu shows.
    var name: String {
        switch self {
        case .center: "Center"
        case .topLeft: "Top Left"
        case .top: "Top"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// How a time generator's text looks: where it sits, how tall it is, its
/// color, and whether a dark box backs it. Everything outside the text and
/// its box is transparent, so the picture layers over a camera.
struct TimeTextStyle: Sendable, Equatable {
    /// Where on the frame the text sits.
    var position: TimeTextPosition

    /// The text's height as a fraction of the frame's height, `0`…`1`.
    var sizeFraction: Double

    /// The text's color.
    var color: ParameterColor

    /// Whether a translucent black box is drawn behind the text, so it
    /// stays legible over a bright picture.
    var hasBacking: Bool
}

/// The appearance parameters the three time generators share — position,
/// size, color, background — declared once so their keys, ranges, and
/// reading rule cannot drift apart. Each generator supplies its own
/// defaults: a time stamp is small and in a corner, a countdown large and
/// centered.
struct TimeTextStyleParameters: Sendable {
    /// The heading a host groups the four parameters under.
    static let section = "Appearance"

    /// `position`: a choice among the ``TimeTextPosition`` cases.
    let position: Parameter

    /// `sizePercent`: the text's height as a percentage of the frame's.
    let size: Parameter

    /// `textColor`: the text's color.
    let color: Parameter

    /// `background`: whether the translucent box backs the text.
    let background: Parameter

    /// Declares the parameters with one generator's defaults.
    ///
    /// - Parameters:
    ///   - defaultPosition: Where the text sits until a host says otherwise.
    ///   - defaultSizePercent: The text's default height, in percent of the
    ///     frame's.
    init(defaultPosition: TimeTextPosition, defaultSizePercent: Double) {
        position = Parameter(
            key: "position",
            name: "Position",
            choices: TimeTextPosition.allCases.map { Parameter.Choice(value: Double($0.rawValue), name: $0.name) },
            defaultValue: Double(defaultPosition.rawValue)
        ).inSection(Self.section)
        size = Parameter(
            key: "sizePercent",
            name: "Size",
            range: 2...50,
            defaultValue: defaultSizePercent,
            unit: "%"
        ).stepped(by: 1).inSection(Self.section)
        color = Parameter(key: "textColor", name: "Color", defaultColor: .white).inSection(Self.section)
        background = Parameter(key: "background", name: "Background", defaultIsOn: true).inSection(Self.section)
    }

    /// The four parameters, in display order.
    var all: [Parameter] { [position, size, color, background] }

    /// Reads the style out of a payload: omitted keys take the declared
    /// defaults, the size is clamped to its range, and a position no case
    /// has falls back to the default.
    ///
    /// - Parameter payload: The host's parameter payload.
    /// - Returns: The style the payload describes.
    func style(in payload: [String: JSONValue]) -> TimeTextStyle {
        let positionValue = position.choice(in: payload)?.value ?? position.defaultValue
        return TimeTextStyle(
            position: TimeTextPosition(rawValue: Int(positionValue)) ?? .center,
            sizeFraction: size.snapped(size.value(in: payload)) / 100,
            color: color.color(in: payload) ?? .white,
            hasBacking: background.isOn(in: payload) ?? true
        )
    }
}
