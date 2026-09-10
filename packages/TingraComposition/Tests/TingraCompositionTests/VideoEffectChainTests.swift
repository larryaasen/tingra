//
//  VideoEffectChainTests.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import Testing
import TingraPlugInKit

@testable import TingraComposition

/// A test effect that appends its tag to a shared order log and grows the
/// extent by a margin, so both signal order and the crop rule are visible.
private struct TaggedEffect: VideoEffect {
    /// The tag written when this effect runs.
    let tag: String

    /// The log every effect in the chain appends to.
    let log: OrderLog

    /// Ignores every payload.
    func setParameters(_ parameters: [String: JSONValue]) {}

    /// Records the run and returns the image over a grown extent.
    func process(_ image: CIImage) -> CIImage {
        log.append(tag)
        return CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: image.extent.insetBy(dx: -8, dy: -8))
    }
}

/// The order in which the tagged effects ran.
private final class OrderLog: @unchecked Sendable {
    /// The tags, in run order.
    private(set) var tags: [String] = []

    /// Appends one tag.
    func append(_ tag: String) { tags.append(tag) }
}

@Suite("VideoEffectChain")
struct VideoEffectChainTests {
    /// A configuration by id, with no parameters.
    private func configuration(_ id: String) -> EffectConfiguration {
        EffectConfiguration(effect: EffectID(rawValue: id))
    }

    @Test("a chain runs its effects in signal order and crops the result to the input's extent")
    func runsInOrderAndCropsToInput() {
        let log = OrderLog()
        var chain = VideoEffectChain(configurations: [configuration("a"), configuration("b")]) { configuration in
            TaggedEffect(tag: configuration.effect.rawValue, log: log)
        }
        #expect(!chain.isEmpty)
        #expect(chain.configurations.map(\.effect.rawValue) == ["a", "b"])

        let input = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(
            to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let output = chain.apply(to: input)
        #expect(log.tags == ["a", "b"])
        // Each effect grew the extent by eight; the chain gives back the
        // input's extent, never more.
        #expect(output.extent == input.extent)
    }

    @Test("a chain with no live instance passes the image through untouched")
    func emptyChainIsIdentity() {
        // A factory that serves nothing: every slot is pass-through.
        var chain = VideoEffectChain(configurations: [configuration("missing")]) { _ in nil }
        #expect(chain.isEmpty)
        let input = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(
            to: CGRect(x: 0, y: 0, width: 4, height: 4))
        #expect(chain.apply(to: input) === input)
    }

    @Test("a slot the factory declines is skipped while the rest still run")
    func declinedSlotIsSkipped() {
        let log = OrderLog()
        var chain = VideoEffectChain(configurations: [configuration("a"), configuration("skip"), configuration("c")]) {
            configuration in
            configuration.effect.rawValue == "skip" ? nil : TaggedEffect(tag: configuration.effect.rawValue, log: log)
        }
        _ = chain.apply(
            to: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)))
        #expect(log.tags == ["a", "c"])
    }
}
