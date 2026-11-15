//
//  ZebraOverlay.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-15.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import TingraPlugInKit

/// Zebra's provider: diagonal stripes over every part of the picture whose
/// luma is at or above a level, 95 % unless the project says otherwise, so
/// highlights about to clip show before they do.
///
/// It stands in for the "show illegal levels" view of the switchers
/// surveyed (PLUGINS.md, "Slice 2 as built"): those mark luma outside the
/// 16–235 video range, which a Tingra monitor never sees, because the
/// working format is 8-bit full-range BGRA and delivery maps it into the
/// video range whole. What an operator can still lose is detail in a
/// highlight driven to the top of the range, and that is what the stripes
/// mark.
public struct ZebraOverlayProvider: MonitorOverlayProvider {
    /// Zebra's stable identifier.
    public static let overlayID = MonitorOverlayID(rawValue: "zebra")

    /// The provider's stable identifier.
    public let id = Self.overlayID

    /// The user-facing name.
    public let name = "Zebra"

    /// A picture overlay: it marks the picture itself.
    public let stage = MonitorOverlayStage.picture

    /// The level, as a share of full luma shown as a percentage.
    public var parameters: [Parameter] {
        [
            Parameter(
                key: ZebraOverlay.levelKey, name: "Level", range: ZebraOverlay.levelRange,
                defaultValue: ZebraOverlay.defaultLevel, unit: "%")
        ]
    }

    /// Creates the provider.
    public init() {}

    /// Makes one monitor's zebra at the payload's level.
    public func makeOverlay(parameters: [String: JSONValue]) -> any MonitorOverlay {
        var overlay = ZebraOverlay()
        overlay.setParameters(parameters)
        return overlay
    }
}

/// Dark diagonal stripes, drawn by a Metal Core Image kernel, wherever the
/// picture's BT.709 luma reaches the level.
struct ZebraOverlay: MonitorOverlay {
    /// The persisted parameter key of the level.
    static let levelKey = "level"

    /// The levels accepted: from half of full luma to full.
    static let levelRange: ClosedRange<Double> = 0.5...1

    /// The level unless the project says otherwise: 95 %, near enough the
    /// top to mark only highlights at risk.
    static let defaultLevel = 0.95

    /// One stripe period in points, a dark band and a clear one; multiplied
    /// by the backing scale, so the stripes look the same on any display.
    static let periodPoints: CGFloat = 8

    /// The luma at and above which the picture is striped, 0 to 1.
    private(set) var level = defaultLevel

    /// Reads the level, clamped to its range; an absent or ill-shaped key
    /// keeps it.
    mutating func setParameters(_ parameters: [String: JSONValue]) {
        if let value = parameters[Self.levelKey]?.doubleValue {
            level = Self.levelRange.clamped(value)
        }
    }

    /// Stripes the picture's highlights. The luma is measured on the
    /// BT.709-encoded values, the code values delivery carries, not on Core
    /// Image's linear working values. A kernel that did not compile draws
    /// nothing.
    func render(over picture: CIImage, in context: MonitorOverlayContext) -> CIImage {
        guard let kernel = ZebraKernel.compiled, !context.pictureRect.isEmpty,
            let rec709 = CGColorSpace(name: CGColorSpace.itur_709),
            let encoded = picture.matchedFromWorkingSpace(to: rec709)
        else { return picture }
        let period = Float(Self.periodPoints * context.backingScale)
        guard
            let stripes = kernel.apply(
                extent: context.pictureRect, arguments: [encoded, Float(level), period])
        else { return picture }
        return stripes.composited(over: picture)
    }
}

/// The zebra's Metal kernel, compiled once from its source on first use.
enum ZebraKernel {
    /// The compiled kernel, or nil when it did not compile. Runtime
    /// compilation (`CIKernel.kernels(withMetalString:)`), the transition
    /// shaders' pattern, keeps the package free of Metal-library build
    /// plumbing; its only input is the fixed source below.
    static let compiled: CIColorKernel? = {
        guard let kernels = try? CIKernel.kernels(withMetalString: source) else { return nil }
        return kernels.first { $0.name == "zebra" } as? CIColorKernel
    }()

    /// The kernel: a sample's BT.709 luma, unpremultiplied, against the
    /// level; at or above it, a 75 % black band on every other half period
    /// of the diagonal, and clear everywhere else.
    static let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[ stitchable ]] float4 zebra(
            coreimage::sample_t s, float level, float period, coreimage::destination dest
        ) {
            if (s.a <= 0.0) { return float4(0.0); }
            float luma = dot(s.rgb / s.a, float3(0.2126, 0.7152, 0.0722));
            if (luma < level) { return float4(0.0); }
            float2 p = dest.coord();
            float band = fmod(p.x + p.y, period);
            float alpha = band < period * 0.5 ? 0.75 : 0.0;
            return float4(0.0, 0.0, 0.0, alpha);
        }
        """
}
