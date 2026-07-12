//
//  MixerView.swift
//  tingra
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraPlugInKit

/// The mixer panel: one channel strip per discovered audio input, each with
/// a mute toggle and a level slider (GLOSSARY.md, "Mixer", "Channel strip").
/// It replaces the streaming panel's single microphone picker — every strip
/// mixes into the program audio the stream carries, and muting a strip also
/// stops its device so the microphone indicator stays honest
/// (ARCHITECTURE.md, "The audio mixer"). Pan, routing, audio effect chains,
/// and meters are later iterations.
///
/// Level edits apply live, tick by tick, like the layer sliders; each
/// control reports its own `tap` event right where it executes — the mute
/// toggle on flip, the slider at drag end (EVENTS.md, "The `tap`
/// convention").
struct MixerView: View {
    /// The engine model whose strips the panel edits.
    @Bindable var model: EngineModel

    /// The panel body: the heading, then a strip per audio input (or a
    /// placeholder when none is discovered).
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mixer", comment: "Section heading over the audio channel strips")
                .font(.headline)

            if model.mixerStrips.isEmpty {
                Text("No audio inputs found", comment: "Mixer placeholder when no audio input is discovered")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.mixerStrips) { strip in
                    stripRow(strip)
                }
            }
        }
    }

    /// One channel strip's row: mute, name, level.
    private func stripRow(_ strip: MixerStrip) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: muteBinding(for: strip.id)) {
                Image(systemName: strip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .toggleStyle(.button)
            .help(Text("Mute", comment: "Help tag on a channel strip's mute toggle"))
            .accessibilityLabel(Text("Mute", comment: "Help tag on a channel strip's mute toggle"))

            Text(strip.name)
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
                .foregroundStyle(strip.isMuted ? .secondary : .primary)

            Slider(value: levelBinding(for: strip.id), in: 0...1) { editing in
                guard !editing else { return }
                let level = model.mixerStrips.first { $0.id == strip.id }?.level ?? 0
                model.eventBus.tap(
                    "mixerLevel.slider",
                    domain: .audio,
                    params: ["id": .string(strip.id.rawValue), "value": .double(level)]
                )
            }
            .accessibilityLabel(Text("Level", comment: "Accessibility label of a channel strip's level slider"))

            Text(strip.level.formatted(.percent.precision(.fractionLength(0))))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .controlSize(.small)
    }

    /// A live binding to one strip's mute, reporting the `tap` before the
    /// model applies it (which also starts or stops the strip's device).
    private func muteBinding(for id: InputID) -> Binding<Bool> {
        Binding {
            model.mixerStrips.first { $0.id == id }?.isMuted ?? false
        } set: { newValue in
            model.eventBus.tap(
                "mixerMute.toggle",
                domain: .audio,
                params: ["id": .string(id.rawValue), "muted": .bool(newValue)]
            )
            Task { await model.setStripMuted(newValue, forStrip: id) }
        }
    }

    /// A live binding to one strip's level, applied to the mix as it drags.
    private func levelBinding(for id: InputID) -> Binding<Double> {
        Binding {
            model.mixerStrips.first { $0.id == id }?.level ?? 0
        } set: { newValue in
            model.setStripLevel(newValue, forStrip: id)
        }
    }
}
