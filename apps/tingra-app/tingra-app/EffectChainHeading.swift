//
//  EffectChainHeading.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI

/// The heading both chain editors share: "Effects" over the one rule an
/// operator must know — the chain runs in the listed order, top to bottom
/// (ARCHITECTURE.md, "The effect chain says its order, and the layer gets
/// a monitor"). A Frame above a Crop is cropped; a Crop above a Frame is
/// framed.
struct EffectChainHeading: View {
    /// Whether the title is a headline (the audio chain's popover, where
    /// it heads the whole surface) rather than the inspector's secondary
    /// caption (one section among the layer's rows).
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Effects", comment: "Heading of a channel strip's audio effect chain popover")
                .font(prominent ? .headline : .caption)
                .foregroundStyle(prominent ? .primary : .secondary)
            Text(
                "Applied in order, top to bottom",
                comment: "Caption under an effect chain's heading: the effects run in the listed order"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// A chain slot's ordinal — "1." before the first effect's name — so the
/// list reads as a sequence, not a set.
struct EffectSlotOrdinal: View {
    /// The slot's zero-based index in the chain.
    let index: Int

    var body: some View {
        Text(verbatim: "\((index + 1).formatted()).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}
