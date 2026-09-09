//
//  MixerView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraAudio
import TingraEventBus
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

    /// The panel body: the heading, then the strips — one row per audio
    /// input, or a placeholder when none is discovered — with the master
    /// column standing at the panel's trailing edge.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mixer", comment: "Section heading over the audio channel strips")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.mixerStrips.isEmpty {
                        Text("No audio inputs found", comment: "Mixer placeholder when no audio input is discovered")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.mixerStrips) { strip in
                            stripRow(strip)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                masterColumn
            }
            // The divider between the strips and the master takes whatever
            // height it is offered, and inside the window's scroll view
            // that offer is unbounded — so the row sizes to its content.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The master section, standing at the mixer panel's trailing edge as
    /// two headed groups side by side (GLOSSARY.md, "Master"). **Master** is
    /// the **post-fader** stereo master meter — the program mix as the
    /// stream and the recording receive it. **Monitor** is the operator's
    /// own listening path: the device they listen through, its level as a
    /// vertical fader, the level's readout, and the monitor mute — the
    /// control room cut, keeping device and level while silencing playback,
    /// the same control as a strip's mute. The groups are divided and
    /// headed separately so a fader standing near the master meter never
    /// reads as a master fader (TODO.md, "Does the recorded mix need a
    /// master fader?").
    ///
    /// **There is deliberately no master fader**: the engine has no master
    /// gain of the operator's, and the monitor level is not one — it scales
    /// only what the operator hears, never the program mix, the stream, or
    /// the recording (ARCHITECTURE.md, "The monitor path").
    private var masterColumn: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                groupHeading(symbol: "waveform", Text("Master", comment: "Label of the mixer's master strip"))

                MasterMeter(relay: model.meterRelay)
            }

            Divider()

            VStack(spacing: 8) {
                groupHeading(
                    symbol: model.isMonitoring && !model.isMonitorMuted ? "headphones" : "headphones.slash",
                    lit: model.isMonitoring && !model.isMonitorMuted,
                    Text("Monitor", comment: "Label of the master strip's monitor device picker")
                )

                Picker(selection: monitorDeviceBinding) {
                    Text("No monitoring", comment: "Monitor device picker entry for monitoring nothing")
                        .tag(String?.none)
                    // A selection with no matching tag is undefined behaviour in
                    // SwiftUI, and this picker has two ways to reach one: the
                    // device list fills asynchronously while the selection is
                    // restored synchronously at launch, and a chosen device can
                    // be unplugged while the app deliberately keeps it selected.
                    // So the absent device gets its own entry rather than the
                    // selection being silently dropped — the dormant channel
                    // strip, one control over.
                    if let uid = dormantMonitorDeviceUID {
                        Text(
                            "\(model.monitorDeviceName ?? uid) (Not connected)",
                            comment: "Picker entry for a selected device that is not currently connected"
                        )
                        .tag(String?.some(uid))
                    }
                    ForEach(model.monitorDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                } label: {
                    Text("Monitor", comment: "Label of the master strip's monitor device picker")
                }
                .labelsHidden()
                .frame(width: 150)
                .help(Text("Monitor", comment: "Label of the master strip's monitor device picker"))
                .accessibilityLabel(
                    Text("Monitor", comment: "Label of the master strip's monitor device picker"))

                VerticalSlider(
                    value: monitorLevelBinding,
                    in: 0...1,
                    label: String(
                        localized: "Monitor level",
                        comment: "Accessibility label of the master strip's monitor level slider")
                ) { editing in
                    guard !editing else { return }
                    model.eventBus.tap(
                        "monitorLevel.slider",
                        domain: .audio,
                        params: ["value": .double(model.monitorLevel)]
                    )
                }
                .frame(height: MasterMeter.length)
                .disabled(model.monitorDeviceUID == nil)

                Text(model.monitorLevel.formatted(.percent.precision(.fractionLength(0))))
                    .foregroundStyle(model.isMonitorMuted ? .tertiary : .secondary)
                    .monospacedDigit()

                Toggle(isOn: monitorMuteBinding) {
                    MuteLabel(isMuted: model.isMonitorMuted)
                }
                .toggleStyle(.button)
                .disabled(model.monitorDeviceUID == nil)
                .help(Text("Mute", comment: "Help tag on a channel strip's mute toggle"))
                .accessibilityLabel(Text("Mute", comment: "Help tag on a channel strip's mute toggle"))
            }
        }
        // The divider between the two groups sizes to the row, as the one
        // between the strips and the master section does.
        .fixedSize(horizontal: false, vertical: true)
        .controlSize(.small)
    }

    /// A heading over one of the master section's groups: a symbol beside
    /// the group's name, weighted so Master and Monitor read as two things.
    /// `lit` draws the symbol in the primary color — the headphones while
    /// the monitor is playing — and otherwise secondary, like an unlit lamp.
    private func groupHeading(symbol: String, lit: Bool = false, _ title: Text) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(lit ? .primary : .secondary)

            title.fontWeight(.semibold)
        }
    }

    /// The selected monitor device's UID when the device list does not
    /// currently contain it, or nil when the selection resolves (or there is
    /// none) — what the picker needs its own entry for.
    private var dormantMonitorDeviceUID: String? {
        guard let uid = model.monitorDeviceUID else { return nil }
        return model.monitorDevices.contains { $0.uid == uid } ? nil : uid
    }

    /// A binding to the monitored device, reporting the picker's `tap` before
    /// the model opens or closes the output path.
    private var monitorDeviceBinding: Binding<String?> {
        Binding {
            model.monitorDeviceUID
        } set: { newValue in
            model.eventBus.tap(
                "monitorDevice.picker",
                domain: .audio,
                params: ["device": .string(newValue ?? "none")]
            )
            Task { await model.setMonitorDevice(newValue) }
        }
    }

    /// A binding to the monitor mute — the control room cut — reporting the
    /// toggle's `tap` before the model silences or restores playback. The
    /// same control as a strip's mute, one group over, so it reads the same.
    private var monitorMuteBinding: Binding<Bool> {
        Binding {
            model.isMonitorMuted
        } set: { newValue in
            model.eventBus.tap(
                "monitorMute.toggle",
                domain: .audio,
                params: ["muted": .bool(newValue)]
            )
            Task { await model.setMonitorMuted(newValue) }
        }
    }

    /// A binding to the monitor level, applied as it drags. Gesture-rate, so
    /// the slider's drag-end `tap` carries the observability.
    private var monitorLevelBinding: Binding<Double> {
        Binding {
            model.monitorLevel
        } set: { newValue in
            Task { await model.setMonitorLevel(newValue) }
        }
    }

    /// One channel strip's row: mute, name (marked when the strip's device
    /// is absent), meter, level, pan, effects.
    private func stripRow(_ strip: MixerStrip) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: muteBinding(for: strip.id)) {
                MuteLabel(isMuted: strip.isMuted)
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

    /// Whether a strip's input is currently discovered. A strip with no
    /// input — an authored channel whose device is absent — stays on the
    /// panel as a dormant strip, contributing silence until it returns.
    private func isConnected(_ strip: MixerStrip) -> Bool {
        model.audioInputs.contains { $0.id == strip.id }
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

/// The label of a mute toggle — a strip's or the monitor's: the speaker
/// symbol, slashed while muted. Sized to the **union of both symbols**,
/// because they differ in glyph width and height and a bordered button
/// sizes to its label — so without this every mute button on the panel
/// jumped a few points as it flipped. Both symbols are laid out, hidden,
/// under the visible one, which keeps the size right at any control size
/// or symbol scale without a hard-coded frame.
struct MuteLabel: View {
    /// Whether the control is muted.
    let isMuted: Bool

    /// The symbol shown while muted.
    private static let mutedSymbol = "speaker.slash.fill"

    /// The symbol shown while live.
    private static let liveSymbol = "speaker.wave.2.fill"

    /// The current symbol over both symbols' footprints.
    var body: some View {
        ZStack {
            Image(systemName: Self.mutedSymbol).hidden()
            Image(systemName: Self.liveSymbol).hidden()
            Image(systemName: isMuted ? Self.mutedSymbol : Self.liveSymbol)
        }
    }
}
