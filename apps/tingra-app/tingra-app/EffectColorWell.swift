//
//  EffectColorWell.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-09.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraPlugInKit

/// The control a chain editor draws for a color effect parameter
/// (`EffectParameter.Kind.color`; ARCHITECTURE.md, "The Frame effect"): the
/// parameter's name beside a color well, shared by the layer chain and the
/// audio chain so the two cannot drift.
///
/// The well is AppKit's, in its minimal style (``ColorWellRepresentable``):
/// clicking the swatch opens a popover of swatches right at the well, with
/// "Show Colors…" inside it for the full panel — Keynote's inspector well.
/// SwiftUI's `ColorPicker` instead opened the shared Colors panel, a
/// floating window that came up on another display, which is why it was
/// replaced.
///
/// A color popover or panel delivers changes continuously while the
/// operator drags, and has no drag-end to report. So the well coalesces a
/// burst into one gesture the way a slider's drag is one: the first change
/// calls `onBegin`, every change calls `onChange` live at gesture rate, and
/// ``settleDelay`` of quiet calls `onEnd` once — where the caller closes
/// its undo step and reports the one `tap`. That is a debounce on the
/// operator's own gesture, the autosave's mechanism, not a poll.
struct EffectColorWell: View {
    /// The parameter the well edits, for its name.
    let parameter: EffectParameter

    /// The parameter's current color.
    let value: EffectColor

    /// Called once at the first change of a burst.
    let onBegin: () -> Void

    /// Called with every new color, at gesture rate.
    let onChange: (EffectColor) -> Void

    /// Called once after the burst has been quiet for ``settleDelay``.
    let onEnd: () -> Void

    /// The pending end-of-burst, replaced by every change.
    @State private var settling: Task<Void, Never>?

    /// How long the well must be quiet before a burst counts as ended —
    /// long enough to ride out a drag's pauses, short enough that an Undo
    /// right after a pick undoes the pick.
    static let settleDelay: Duration = .milliseconds(500)

    /// The well: the parameter's name, then the swatch.
    var body: some View {
        HStack(spacing: 4) {
            Text(parameter.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            ColorWellRepresentable(color: value, accessibilityLabel: parameter.name, onChange: changed)
                .fixedSize()

            Spacer()
        }
        .onDisappear(perform: finishNow)
    }

    /// Folds one change from the well into the burst.
    private func changed(_ color: EffectColor) {
        guard color != value else { return }
        if settling == nil {
            onBegin()
        }
        settling?.cancel()
        onChange(color)
        settling = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            settling = nil
            onEnd()
        }
    }

    /// Ends an open burst immediately — the well is leaving the screen, so
    /// its undo step must close now rather than after the delay.
    private func finishNow() {
        guard settling != nil else { return }
        settling?.cancel()
        settling = nil
        onEnd()
    }
}

/// An `NSColorWell` in its minimal style, hosted in SwiftUI: a swatch that
/// opens a popover at the well, and continuous change delivery through
/// `onChange`. AppKit where SwiftUI does not yet cover the need
/// (CLAUDE.md) — SwiftUI's `ColorPicker` cannot choose the well's style.
struct ColorWellRepresentable: NSViewRepresentable {
    /// The color the well shows.
    let color: EffectColor

    /// The well's accessibility label — the parameter's name.
    let accessibilityLabel: String

    /// Called with every color the well delivers, at gesture rate.
    let onChange: (EffectColor) -> Void

    /// Creates the well, wired to the coordinator for its changes.
    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(style: .minimal)
        well.supportsAlpha = true
        well.isContinuous = true
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        well.setAccessibilityLabel(accessibilityLabel)
        return well
    }

    /// Pushes the model's color into the well — only when it differs, so a
    /// change the well itself just delivered does not bounce back into it
    /// and unsettle an open popover.
    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.onChange = onChange
        guard EffectColor(well.color) != color else { return }
        well.color = NSColor(color)
    }

    /// Creates the coordinator carrying the change handler.
    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    /// The well's target: forwards each change as an `EffectColor`.
    final class Coordinator: NSObject {
        /// The current change handler (refreshed on every update).
        var onChange: (EffectColor) -> Void

        /// Creates the coordinator with its first handler.
        init(onChange: @escaping (EffectColor) -> Void) {
            self.onChange = onChange
        }

        /// The well's action: the operator picked or dragged a color.
        @objc func colorChanged(_ sender: NSColorWell) {
            onChange(EffectColor(sender.color))
        }
    }
}

extension NSColor {
    /// The AppKit color of an effect color: sRGB components as they are.
    convenience init(_ color: EffectColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension EffectColor {
    /// The effect color of an AppKit color, converted to sRGB — what the
    /// well hands back. A color that cannot be expressed in sRGB (a pattern)
    /// falls back to opaque black rather than a guess.
    init(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            self = .black
            return
        }
        self.init(
            red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }
}
