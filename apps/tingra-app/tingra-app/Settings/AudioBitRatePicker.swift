//
//  AudioBitRatePicker.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraHost

/// The menu of audio bit rates the Streaming and Recording settings panes
/// share (ARCHITECTURE.md, "Compression settings in the app"): one row per
/// rate in ``CompressionChoices/audioBitRates``, read in kilobits per
/// second, the unit a destination's own recommendation is written in.
///
/// One view for both panes so the two menus cannot drift apart; each pane
/// supplies its own binding, which is where the tap is reported and the
/// choice is stored.
struct AudioBitRatePicker: View {
    /// The chosen rate in bits per second.
    @Binding var bitsPerSecond: Int

    var body: some View {
        Picker(selection: $bitsPerSecond) {
            ForEach(CompressionChoices.audioBitRates, id: \.self) { rate in
                Text(verbatim: Self.label(for: rate)).tag(rate)
            }
        } label: {
            Text("Audio Bit Rate", comment: "Streaming and Recording settings: audio bit rate picker label")
        }
        .pickerStyle(.menu)
    }

    /// The row title for a rate: whole kilobits per second, such as
    /// "160 kbps". Verbatim like the live "kbps" readings beside it — a unit
    /// abbreviation, not a phrase.
    ///
    /// - Parameter bitsPerSecond: The rate in bits per second.
    /// - Returns: The title.
    static func label(for bitsPerSecond: Int) -> String {
        "\((bitsPerSecond / 1000).formatted(.number.grouping(.never))) kbps"
    }
}
