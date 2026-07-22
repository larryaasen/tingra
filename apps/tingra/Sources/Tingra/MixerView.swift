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

/// The mixer panel: one channel strip per authored audio channel and per
/// discovered audio input, each with a mute toggle, a meter, a level slider,
/// a pan slider, and an effect chain (GLOSSARY.md, "Mixer", "Channel
/// strip"). Every strip mixes into the program audio the stream carries,
/// and muting a strip also stops its device so the microphone indicator
/// stays honest (ARCHITECTURE.md, "The audio mixer"). Strip settings
/// persist in the active preset; a strip whose device is absent stays on
/// the panel, marked not connected, its settings editable and kept for the
/// device's return (ARCHITECTURE.md, "Per-strip routing").
///
/// Level and pan edits apply live, tick by tick, like the layer sliders;
/// each control reports its own `tap` event right where it executes — the
/// mute toggle on flip, the sliders at drag end (EVENTS.md, "The `tap`
/// convention"). The pan slider seeds centered and double-clicking recenters
/// it, the macOS convention for a slider with a meaningful default.
struct MixerView: View {
    /// The engine model whose strips the panel edits.
    @Bindable var model: EngineModel

    /// The strip whose effect chain popover is open, if any — view-local
    /// session state, like any other popover presentation.
    @State private var chainStripID: InputID?

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

    /// One channel strip's row: mute, name (marked when the strip's device
    /// is absent), meter, level, pan, effects.
    private func stripRow(_ strip: MixerStrip) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: muteBinding(for: strip.id)) {
                Image(systemName: strip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .toggleStyle(.button)
            .help(Text("Mute", comment: "Help tag on a channel strip's mute toggle"))
            .accessibilityLabel(Text("Mute", comment: "Help tag on a channel strip's mute toggle"))

            HStack(spacing: 4) {
                Text(strip.name)
                    .lineLimit(1)
                    .foregroundStyle(strip.isMuted || !isConnected(strip) ? .secondary : .primary)
                if !isConnected(strip) {
                    // A dormant strip: its authored channel persists while its
                    // device is absent — silence until the device returns.
                    Image(systemName: "mic.slash")
                        .foregroundStyle(.secondary)
                        .help(Text("Not connected", comment: "Help tag on a channel strip whose device is absent"))
                        .accessibilityLabel(
                            Text("Not connected", comment: "Help tag on a channel strip whose device is absent"))
                }
            }
            .frame(width: 180, alignment: .leading)

            StripMeter(relay: model.meterRelay, id: strip.id)

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

            panSlider(for: strip)

            effectsButton(for: strip)
        }
        .controlSize(.small)
    }

    /// One strip's Effects button: opens the chain popover, badged with
    /// the chain's length so a strip's processing is visible at a glance
    /// on the panel (a console's insert indicator).
    private func effectsButton(for strip: MixerStrip) -> some View {
        Button {
            model.eventBus.tap(
                "effects.button",
                domain: .audio,
                params: ["id": .string(strip.id.rawValue), "count": .int(strip.effects.count)]
            )
            chainStripID = strip.id
        } label: {
            HStack(spacing: 2) {
                Image(
                    systemName: strip.effects.isEmpty
                        ? "slider.horizontal.3" : "slider.horizontal.below.square.filled.and.square")
                if !strip.effects.isEmpty {
                    Text(strip.effects.count.formatted())
                        .monospacedDigit()
                }
            }
        }
        .help(Text("Effects", comment: "Heading of a channel strip's audio effect chain popover"))
        .accessibilityLabel(Text("Effects", comment: "Heading of a channel strip's audio effect chain popover"))
        .popover(isPresented: chainPopoverBinding(for: strip.id)) {
            EffectChainView(model: model, stripID: strip.id)
        }
    }

    /// A binding presenting the chain popover for one strip — the shared
    /// ``chainStripID`` expressed per strip, so only one popover is open.
    private func chainPopoverBinding(for id: InputID) -> Binding<Bool> {
        Binding {
            chainStripID == id
        } set: { isPresented in
            chainStripID = isPresented ? id : nil
        }
    }

    /// One strip's pan slider: hard left to hard right around a centered
    /// default, flanked by the broadcast L/R value labels. The drag-end
    /// `tap` reports where the pan landed; a double-click recenters it (the
    /// macOS slider-reset convention), reporting its own `tap` since a reset
    /// is a discrete action, not a drag.
    private func panSlider(for strip: MixerStrip) -> some View {
        Slider(value: panBinding(for: strip.id), in: -1...1) {
            Text("Pan", comment: "Label of a channel strip's pan slider")
        } minimumValueLabel: {
            Text("L", comment: "Left label beside a channel strip's pan slider")
        } maximumValueLabel: {
            Text("R", comment: "Right label beside a channel strip's pan slider")
        } onEditingChanged: { editing in
            guard !editing else { return }
            let pan = model.mixerStrips.first { $0.id == strip.id }?.pan ?? 0
            model.eventBus.tap(
                "mixerPan.slider",
                domain: .audio,
                params: ["id": .string(strip.id.rawValue), "value": .double(pan)]
            )
        }
        .labelsHidden()
        .frame(width: 110)
        .help(Text("Pan", comment: "Label of a channel strip's pan slider"))
        .accessibilityLabel(Text("Pan", comment: "Label of a channel strip's pan slider"))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                model.eventBus.tap(
                    "mixerPan.reset",
                    domain: .audio,
                    params: ["id": .string(strip.id.rawValue)]
                )
                model.setStripPan(0, forStrip: strip.id)
            }
        )
    }

    /// Whether a strip's device is currently discovered. A strip with no
    /// device — an authored channel whose device is absent — stays on the
    /// panel as a dormant strip, contributing silence until it returns.
    private func isConnected(_ strip: MixerStrip) -> Bool {
        model.microphones.contains { $0.id == strip.id }
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

    /// A live binding to one strip's pan, applied to the mix as it drags.
    private func panBinding(for id: InputID) -> Binding<Double> {
        Binding {
            model.mixerStrips.first { $0.id == id }?.pan ?? 0
        } set: { newValue in
            model.setStripPan(newValue, forStrip: id)
        }
    }
}
