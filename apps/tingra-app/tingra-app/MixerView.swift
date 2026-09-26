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
/// discovered audio input, each a **column** laid out as a console strip —
/// the name, the Effects button, the pan slider, the peak-hold readout, the
/// fader standing beside the meter, the level readout, and the mute at the
/// foot (GLOSSARY.md, "Mixer", "Channel strip", "Fader"; ARCHITECTURE.md,
/// "The console mixer"). Every strip mixes into the program audio the
/// stream carries, and muting a strip also stops its device so the
/// microphone indicator stays honest (ARCHITECTURE.md, "The audio mixer").
/// Strip settings persist in the active preset; a strip whose device is
/// absent stays on the panel, marked not connected, its settings editable
/// and kept for the device's return (ARCHITECTURE.md, "Per-strip routing").
///
/// The strips sit side by side in a horizontal scroll view, so a show with
/// many audio inputs grows the panel sideways rather than taller; the
/// master column keeps its place at the trailing edge, outside the scroll.
///
/// Faders read in decibels through ``FaderScale`` while the engine and the
/// document keep linear gain. Level and pan edits apply live, tick by tick,
/// like the layer sliders; each control reports its own `tap` event right
/// where it executes — the mute toggle on flip, the sliders at drag end
/// (EVENTS.md, "The `tap` convention"). A double-click returns a fader to
/// unity and the pan slider to center, the macOS convention for a control
/// with a meaningful default, each reporting its own reset `tap`.
struct MixerView: View {
    /// The engine model whose strips the panel edits.
    @Bindable var model: EngineModel

    /// The strip whose effect chain popover is open, if any — view-local
    /// session state, like any other popover presentation.
    @State private var chainStripID: InputID?

    /// The strip whose Input Settings popover is open, if any — the same
    /// view-local presentation state, one popover at a time.
    @State private var settingsStripID: InputID?

    /// A strip column's width in points: enough for a fader beside a meter,
    /// a short pan slider, and a truncating name.
    static let stripWidth: CGFloat = 92

    /// The panel body: the heading, then the strips — one column per audio
    /// input in a horizontal scroll, or a placeholder when none is
    /// discovered — with the master column standing at the panel's trailing
    /// edge.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mixer", comment: "Section heading over the audio channel strips")
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                if model.mixerStrips.isEmpty {
                    Text("No audio inputs found", comment: "Mixer placeholder when no audio input is discovered")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(model.mixerStrips) { strip in
                                stripColumn(strip)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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
    /// the **post-fader** stereo master meter under its peak-hold readout —
    /// the program mix as the stream and the recording receive it.
    /// **Monitor** is the operator's own listening path: the device they
    /// listen through, its level as a vertical fader read in decibels, the
    /// level's readout, and the monitor mute — the control room cut, keeping
    /// device and level while silencing playback, the same control as a
    /// strip's mute. The groups are divided and headed separately so a fader
    /// standing near the master meter never reads as a master fader
    /// (TODO.md, "Does the recorded mix need a master fader?").
    ///
    /// **There is deliberately no master fader**: the engine has no master
    /// gain of the operator's, and the monitor level is not one — it scales
    /// only what the operator hears, never the program mix, the stream, or
    /// the recording (ARCHITECTURE.md, "The monitor path"). Its fader
    /// therefore tops out at unity (``FaderScale/monitor``): the playback
    /// gain clamps at 1, and a fader whose top quarter did nothing would lie.
    private var masterColumn: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                groupHeading(symbol: "waveform", Text("Master", comment: "Label of the mixer's master strip"))

                PeakReadout(relay: model.meterRelay, subject: .master, eventBus: model.eventBus)

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
                        comment: "Accessibility label of the master strip's monitor level slider"),
                    onDoubleClick: {
                        model.eventBus.tap("monitorLevel.reset", domain: .audio)
                        Task { await model.setMonitorLevel(1) }
                    }
                ) { editing in
                    guard !editing else { return }
                    model.eventBus.tap(
                        "monitorLevel.slider",
                        domain: .audio,
                        // Three decimal places: the gain's full precision
                        // (0.08256329203882862) is noise in a log line.
                        params: ["value": .double((model.monitorLevel * 1000).rounded() / 1000)]
                    )
                }
                .frame(height: MasterMeter.length)
                .disabled(model.monitorDeviceUID == nil)

                levelReadout(gain: model.monitorLevel, dimmed: model.isMonitorMuted)

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

    /// A fader's readout: the gain in decibels to one decimal with an
    /// explicit sign, or `−∞` at silence (``FaderScale/readout(forGain:)``).
    /// `dimmed` draws it tertiary — the monitor's while muted.
    private func levelReadout(gain: Double, dimmed: Bool) -> some View {
        Group {
            if let figure = FaderScale.readout(forGain: gain) {
                Text("\(figure) dB", comment: "A fader's readout: its gain in decibels")
            } else {
                Text("−∞ dB", comment: "A fader's readout at silence")
            }
        }
        .foregroundStyle(dimmed ? .tertiary : .secondary)
        .monospacedDigit()
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

    /// A binding to the monitor fader's position on ``FaderScale/monitor``,
    /// applying the gain it stands for as it drags. Gesture-rate, so the
    /// slider's drag-end `tap` carries the observability.
    private var monitorLevelBinding: Binding<Double> {
        Binding {
            FaderScale.monitor.position(forGain: model.monitorLevel)
        } set: { newValue in
            let gain = FaderScale.monitor.gain(forPosition: newValue)
            Task { await model.setMonitorLevel(gain) }
        }
    }

    /// One channel strip's column, top to bottom: the name (marked when the
    /// strip's device is absent), Effects, pan, the peak readout, the fader
    /// beside the meter, the level readout, and the mute.
    ///
    /// The name wraps to **two lines** (Larry, 2026-09-13) — a device name
    /// like "MacBook Pro Microphone" is three words, and one line at 92
    /// points showed the first and an ellipsis — and it reserves those two
    /// lines whether it needs them or not, so every strip's Effects button,
    /// pan, and fader sit at the same height across the row. A name longer
    /// still truncates at the end, with the full name as the help tag.
    private func stripColumn(_ strip: MixerStrip) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(strip.name)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
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
            .help(Text(strip.name))

            HStack(spacing: 4) {
                effectsButton(for: strip)
                settingsButton(for: strip)
            }

            panSlider(for: strip)

            PeakReadout(relay: model.meterRelay, subject: .strip(strip.id), eventBus: model.eventBus)

            HStack(spacing: 6) {
                VerticalSlider(
                    value: levelPositionBinding(for: strip.id),
                    in: 0...1,
                    label: String(localized: "Level", comment: "Accessibility label of a channel strip's level slider"),
                    onDoubleClick: {
                        model.eventBus.tap(
                            "mixerLevel.reset",
                            domain: .audio,
                            params: ["id": .string(strip.id.rawValue)]
                        )
                        model.setStripLevel(1, forStrip: strip.id)
                    }
                ) { editing in
                    guard !editing else { return }
                    let level = model.mixerStrips.first { $0.id == strip.id }?.level ?? 0
                    model.eventBus.tap(
                        "mixerLevel.slider",
                        domain: .audio,
                        params: ["id": .string(strip.id.rawValue), "value": .double(level)]
                    )
                }
                .frame(height: MasterMeter.length)

                StripMeter(relay: model.meterRelay, id: strip.id)
            }

            levelReadout(gain: strip.level, dimmed: strip.isMuted)

            Toggle(isOn: muteBinding(for: strip.id)) {
                MuteLabel(isMuted: strip.isMuted)
            }
            .toggleStyle(.button)
            .help(Text("Mute", comment: "Help tag on a channel strip's mute toggle"))
            .accessibilityLabel(Text("Mute", comment: "Help tag on a channel strip's mute toggle"))
        }
        .frame(width: Self.stripWidth)
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

    /// One strip's Input Settings button — present only when the strip's
    /// input declares parameters (PLUGINS.md, Decision 15): the 440 Hz
    /// tone's frequency and level today, a third-party input's settings
    /// tomorrow, drawn by the same popover with no app code for either. A
    /// microphone declares nothing and shows no button.
    @ViewBuilder private func settingsButton(for strip: MixerStrip) -> some View {
        if model.declaredInputParameters[strip.id]?.isEmpty == false {
            Button {
                model.eventBus.tap(
                    "inputSettings.button",
                    domain: .audio,
                    params: ["id": .string(strip.id.rawValue)]
                )
                settingsStripID = strip.id
            } label: {
                Image(systemName: "gearshape")
            }
            .help(
                Text(
                    "Input Settings", comment: "Heading of an input's settings popover, over the parameters it declares"
                )
            )
            .accessibilityLabel(
                Text(
                    "Input Settings", comment: "Heading of an input's settings popover, over the parameters it declares"
                )
            )
            .popover(isPresented: settingsPopoverBinding(for: strip.id)) {
                InputParametersView(model: model, inputID: strip.id)
            }
        }
    }

    /// A binding presenting the Input Settings popover for one strip — the
    /// shared ``settingsStripID`` expressed per strip.
    private func settingsPopoverBinding(for id: InputID) -> Binding<Bool> {
        Binding {
            settingsStripID == id
        } set: { isPresented in
            settingsStripID = isPresented ? id : nil
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

    /// A live binding to one strip's fader position on ``FaderScale/strip``,
    /// applying the gain it stands for to the mix as it drags.
    private func levelPositionBinding(for id: InputID) -> Binding<Double> {
        Binding {
            FaderScale.strip.position(forGain: model.mixerStrips.first { $0.id == id }?.level ?? 0)
        } set: { newValue in
            model.setStripLevel(FaderScale.strip.gain(forPosition: newValue), forStrip: id)
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
