//
//  EngineModel+Inputs.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraComposition
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// Input discovery, names, and parameters, kept current from device events.
extension EngineModel {
    /// The discovered inputs producing the given media, in a stable
    /// name order so a picker does not reshuffle when another device
    /// connects (`InputRegistry.allInputs` is dictionary-ordered).
    ///
    /// - Parameters:
    ///   - inputs: The discovered inputs to filter.
    ///   - media: The media a choice must produce to be included.
    /// - Returns: The matching inputs as view-facing choices.
    nonisolated static func mediaChoices(
        from inputs: [any Input],
        producing media: InputMedia
    ) -> [InputChoice] {
        inputs
            .filter { $0.media.contains(media) }
            .map { InputChoice(id: $0.id, name: $0.name, kind: $0.kind) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The inputs a new layer can bind to: everything that produces video.
    /// Generators are in — the exclusion that stood here was never about
    /// generators as such, only about `InputKind` being unable to say
    /// whether one produced video or audio (see ARCHITECTURE.md, "The
    /// `Input` media capability").
    var layerInputChoices: [InputChoice] {
        videoInputs
    }

    /// Whether a layer's input is currently discovered — a layer bound to a
    /// device that went away stays bound and dormant, and the editor's list
    /// draws it dimmed (ARCHITECTURE.md, "Direct manipulation, drag-to-reorder,
    /// and undo in the layer-tree editor").
    ///
    /// - Parameter id: The layer's input.
    /// - Returns: Whether that input can contribute frames now.
    func isInputAvailable(_ id: InputID) -> Bool {
        layerInputChoices.contains { $0.id == id }
    }

    /// The sidebar's symbol for an input's kind, so a layer row and the
    /// inspector's header read like the sidebar row the input came from —
    /// and a warning for a layer whose input is not discovered.
    ///
    /// - Parameter id: The layer's input.
    /// - Returns: An SF Symbol name.
    func kindSymbol(forInput id: InputID) -> String {
        switch layerInputChoices.first(where: { $0.id == id })?.kind {
        case .camera: "video"
        case .display: "display"
        case .window: "macwindow"
        case .generator: "rectangle.checkered"
        case .microphone: "mic"
        case .application: "app"
        // A media input's symbol says what kind of file it is, resolved
        // from the item's content type (ARCHITECTURE.md, "Media inputs and
        // the Library's Media tab").
        case .media:
            LibraryItem.kind(of: mediaItem(forInput: id).flatMap { MediaRegistry.contentType(of: $0.url) }).symbol
        case nil: "exclamationmark.triangle"
        // A kind a later kit adds gets a generic symbol until this mapping
        // names it.
        @unknown default: "questionmark.square.dashed"
        }
    }

    /// Rebuilds every device list from the input registry.
    ///
    /// **From the registry, never from a device event's params** — the whole
    /// reason this is sound. The capture plug-ins update the registry *before*
    /// they emit `device.connected`/`device.disconnected`, so a listener
    /// reacting to the event always sees the registry already reflecting it;
    /// rebuilding from it therefore cannot drift, and one code path serves
    /// both boot and every later change. This is what `devices --watch` does
    /// (ARCHITECTURE.md, "Live device lists in the app").
    func readDeviceLists() async {
        let inputs = await registry.allInputs
        // The camera and display pickers ask a *provenance* question —
        // "choose a camera" — so they filter on kind; listing a generator
        // among the cameras would be wrong. The two media-role lists below
        // ask "what does this produce" and filter on media instead.
        cameras = inputs.filter { $0.kind == .camera }
            .map { InputChoice(id: $0.id, name: $0.name, kind: .camera) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        displays = inputs.filter { $0.kind == .display }
            .map { InputChoice(id: $0.id, name: $0.name, kind: .display) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        windowInputs = inputs.filter { $0.kind == .window }
            .map { InputChoice(id: $0.id, name: $0.name, kind: .window) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        videoInputs = Self.mediaChoices(from: inputs, producing: .video)
        audioInputs = Self.mediaChoices(from: inputs, producing: .audio)
        rememberInputNames(from: inputs)
        await applyInputParameters(to: inputs)
    }

    /// Records which inputs declare parameters and hands each of them the
    /// project's stored values. An input the project stores nothing for gets
    /// the values it reports holding itself (`Input.currentParameters`): an
    /// input whose settings live only in the host reports none, so the empty
    /// payload restores its declared defaults and an input tuned by the
    /// previous project is not left tuned; a device that keeps its own
    /// settings — a UVC camera — reports them, so applying them changes
    /// nothing and opening a project never resets the camera's picture
    /// (docs/UVC.md). Runs with every device-list rebuild, because a device
    /// that reconnects is a fresh input instance that knows nothing of the
    /// project's settings.
    ///
    /// - Parameter inputs: The inputs currently in the registry.
    private func applyInputParameters(to inputs: [any Input]) async {
        var declared: [InputID: [Parameter]] = [:]
        var deviceValues: [InputID: [String: JSONValue]] = [:]
        for input in inputs {
            let parameters = input.parameters
            guard !parameters.isEmpty else { continue }
            declared[input.id] = parameters
            if let stored = inputParameters[input.id] {
                await input.setParameters(stored)
                continue
            }
            let current = await input.currentParameters()
            if !current.isEmpty {
                deviceValues[input.id] = current
            }
            await input.setParameters(current)
        }
        declaredInputParameters = declared
        deviceInputParameters = deviceValues
    }

    /// One input's parameter values as the settings popover shows them: the
    /// project's stored values, else the values the device keeps for itself.
    ///
    /// - Parameter id: The input.
    /// - Returns: The payload; empty when neither exists.
    func inputParameterValues(for id: InputID) -> [String: JSONValue] {
        inputParameters[id] ?? deviceInputParameters[id] ?? [:]
    }

    /// Applies the open project's stored input settings to every registered
    /// input — what a project load calls once the document is read, since
    /// the device lists were built before it was.
    func applyStoredInputParameters() async {
        await applyInputParameters(to: registry.allInputs)
    }

    /// Sets one declared parameter of one input — the settings popover's
    /// slider, field, or color well — storing the value with the project
    /// and applying the whole payload to the input, live. A gesture-rate
    /// control like the effect parameters: the value reaches the input at
    /// once, no event is reported (the control reports its own `tap`), and
    /// the autosave is debounced.
    ///
    /// - Parameters:
    ///   - value: The parameter's new payload value.
    ///   - key: The parameter's persisted key.
    ///   - id: The input whose parameter changes.
    func setInputParameter(_ value: JSONValue, forKey key: String, ofInput id: InputID) {
        // The first edit of a device-held setting starts from the device's
        // values, so storing it does not reset the others to defaults.
        var payload = inputParameterValues(for: id)
        guard payload[key] != value else { return }
        payload[key] = value
        inputParameters[id] = payload
        let previous = inputParameterApplyTask
        inputParameterApplyTask = Task { [registry] in
            await previous?.value
            guard let input = await registry.input(withID: id) else { return }
            await input.setParameters(payload)
        }
        scheduleAutosave()
    }

    /// Records every discovered input's current name, so a picker can still
    /// label a selection whose device has since gone away.
    ///
    /// Only ever *adds* — a departed device keeps the name it was last seen
    /// under, which is exactly when the cache is needed. Session-scoped
    /// deliberately: a device name is not part of the show, so it never
    /// enters the project document, and an unknown id simply falls back to the
    /// raw identifier the way the layer editor's rows already do.
    ///
    /// - Parameter inputs: The inputs currently in the registry.
    private func rememberInputNames(from inputs: [any Input]) {
        for input in inputs {
            lastKnownInputNames[input.id] = input.name
        }
    }

    /// Refreshes the device lists after a `device.connected` /
    /// `device.disconnected` event, then reruns both reconfigure passes.
    ///
    /// Every other event is ignored, so this shares the bus consumer with the
    /// stream-status handler at no cost. Device connection and disconnection
    /// are **normal events, never errors**, so
    /// there is nothing to surface as a failure — the lists simply change.
    ///
    /// - Parameter event: An event drained from the bus.
    func handleDeviceEvent(_ event: EventBusEvent) async {
        guard event.name == "device.connected" || event.name == "device.disconnected" else { return }
        // A connection is a topology change, and the one a silent input
        // needs: a lid opening connects the built-in display, a hub
        // re-enumerating brings a stalled camera back. Every silent input is
        // retried on the next pass; a disconnection changes nothing for them.
        if event.name == "device.connected" { silentInputs.removeAll() }
        await readDeviceLists()
        await refreshMixerStrips()
        // The video pass stops an input that has left and starts one whose
        // device has returned; both coalesce, so a burst of arrivals (a dock
        // carrying a camera and a display) costs one pass each.
        await reconfigure()
    }

    /// The user-facing name of an input, for the editor's layer rows and for
    /// the inspector's entry for a device that has gone away.
    ///
    /// Falls back through the name discovery last reported, then the raw
    /// identifier — an edited layer can outlive its device (see
    /// ``lastKnownInputNames``).
    ///
    /// - Parameter id: The input's stable identifier.
    func inputName(for id: InputID) -> String {
        layerInputChoices.first { $0.id == id }?.name ?? lastKnownInputNames[id] ?? id.rawValue
    }
}
