//
//  VUMetersOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import CoreImage
import TingraPlugInKit

/// VU Meters' provider: a bar per audio channel up the picture's right
/// edge, so the operator watching a monitor sees its sound without looking
/// away to the mixer. The program monitor shows the program mix's left and
/// right; an input tile and the layer monitor show that input's level. The
/// preview monitor has no sound of its own, so the overlay is unavailable
/// there.
public struct VUMetersOverlayProvider: MonitorOverlayProvider {
    /// VU Meters' stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "vuMeters")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "VU Meters"

    /// A guide: drawn over the picture.
    public let stage = MonitorOverlayStage.guide

    /// No settings: the scale and colors are the mixer's.
    public var parameters: [Parameter] { [] }

    /// The meters draw the monitor's levels.
    public var usesAudioLevels: Bool { true }

    /// Creates the provider.
    public init() {}

    /// Every monitor with sound: not preview, which has none of its own.
    ///
    /// - Parameter monitor: The monitor asked about.
    /// - Returns: Whether the monitor has levels to show.
    public func isAvailable(on monitor: MonitorOverlayContext.Monitor) -> Bool {
        switch monitor {
        case .preview: false
        case .program, .input, .layer: true
        @unknown default: true
        }
    }

    /// Makes one monitor's meters.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        VUMetersOverlay()
    }
}

/// Bars up the picture's right edge: a dark track per channel, filled from
/// the bottom to the channel's RMS on the mixer's dBFS scale in green,
/// yellow above −18 dBFS, and red above −6, with a white tick at the peak.
struct VUMetersOverlay: MonitorOverlay {
    /// The quietest level a bar shows, in dBFS: the bottom of the track.
    static let floorDecibels: Double = -60

    /// Where the bar turns from green to yellow, in dBFS.
    static let cautionDecibels: Double = -18

    /// Where the bar turns from yellow to red, in dBFS.
    static let dangerDecibels: Double = -6

    /// One bar's width in points.
    static let barWidthPoints: CGFloat = 6

    /// The gap between two bars, in points.
    static let gapPoints: CGFloat = 2

    /// The margin between the bars and the picture's edges, in points.
    static let marginPoints: CGFloat = 8

    /// The track's color: black at half opacity.
    static let trackColor = ParameterColor(red: 0, green: 0, blue: 0, alpha: 0.5)

    /// The fill below the caution level.
    static let safeColor = ParameterColor(red: 0.2, green: 0.78, blue: 0.35)

    /// The fill between the caution and danger levels.
    static let cautionColor = ParameterColor(red: 1, green: 0.8, blue: 0)

    /// The fill above the danger level.
    static let dangerColor = ParameterColor(red: 1, green: 0.23, blue: 0.19)

    /// The peak tick's color.
    static let peakColor = ParameterColor(red: 1, green: 1, blue: 1)

    /// Nothing to set.
    mutating func setParameters(_ parameters: [String: JSONValue]) {}

    /// Draws a bar per channel; nothing when the monitor has no levels.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        let tracks = Self.tracks(
            in: context.pictureRect, count: context.audioLevels.count, backingScale: context.backingScale)
        guard !tracks.isEmpty else { return picture }
        var image = GuideDrawing.fill(tracks, color: Self.trackColor, over: picture)
        for (track, level) in zip(tracks, context.audioLevels) {
            for (segment, color) in Self.segments(of: track, filledTo: Self.fraction(of: level.rms)) {
                image = GuideDrawing.fill([segment], color: color, over: image)
            }
            let tickHeight = GuideDrawing.pixels(1, in: context)
            let peakY = track.minY + track.height * Self.fraction(of: level.peak)
            let tick = CGRect(
                x: track.minX, y: min(peakY, track.maxY - tickHeight), width: track.width, height: tickHeight)
            image = GuideDrawing.fill(
                [MonitorGuideGeometry.snapped(tick)], color: Self.peakColor, over: image)
        }
        return image
    }

    /// The bars' tracks: one per channel, side by side against the
    /// picture's right margin with the first channel leftmost, full height
    /// inside the margins.
    ///
    /// - Parameters:
    ///   - picture: The fitted picture's rectangle.
    ///   - count: The number of channels.
    ///   - backingScale: Drawable pixels per point.
    /// - Returns: The tracks, in channel order; none when there are no
    ///   channels or the picture is too small to hold them.
    static func tracks(in picture: CGRect, count: Int, backingScale: CGFloat) -> [CGRect] {
        let bar = (barWidthPoints * backingScale).rounded()
        let gap = (gapPoints * backingScale).rounded()
        let margin = (marginPoints * backingScale).rounded()
        let width = CGFloat(count) * bar + CGFloat(max(0, count - 1)) * gap
        let height = picture.height - 2 * margin
        guard count > 0, height > 0, width + 2 * margin <= picture.width else { return [] }
        let left = picture.maxX - margin - width
        return (0..<count).map { index in
            MonitorGuideGeometry.snapped(
                CGRect(x: left + CGFloat(index) * (bar + gap), y: picture.minY + margin, width: bar, height: height))
        }
    }

    /// Where a linear level sits on the track, 0 at the floor and 1 at
    /// full scale.
    ///
    /// - Parameter level: A sample magnitude, 0 to 1.
    /// - Returns: The share of the track's height.
    static func fraction(of level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return CGFloat(min(1, max(0, (decibels - floorDecibels) / -floorDecibels)))
    }

    /// The fill of a track up to a share of its height, cut into its green,
    /// yellow, and red segments.
    ///
    /// - Parameters:
    ///   - track: The track.
    ///   - fraction: How much of it is filled, 0 to 1.
    /// - Returns: The filled segments with their colors, bottom up.
    static func segments(of track: CGRect, filledTo fraction: CGFloat) -> [(CGRect, ParameterColor)] {
        let top = track.minY + track.height * fraction
        let caution = track.minY + track.height * Self.fraction(of: Float(pow(10, cautionDecibels / 20)))
        let danger = track.minY + track.height * Self.fraction(of: Float(pow(10, dangerDecibels / 20)))
        let bands: [(CGFloat, CGFloat, ParameterColor)] = [
            (track.minY, caution, safeColor), (caution, danger, cautionColor), (danger, track.maxY, dangerColor),
        ]
        return bands.compactMap { bottom, bandTop, color in
            let upper = min(top, bandTop)
            guard upper > bottom else { return nil }
            return (CGRect(x: track.minX, y: bottom, width: track.width, height: upper - bottom), color)
        }
    }
}
