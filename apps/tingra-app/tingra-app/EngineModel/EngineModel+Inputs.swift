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

    /// The inputs a new layer can bind to: everything that produces video,
    /// generators included (ARCHITECTURE.md, "The `Input` media capability").
    var layerInputChoices: [InputChoice] {
        videoInputs
    }

    /// Whether a layer's input is currently discovered. A layer whose device
    /// went away stays bound, dormant, and dimmed (ARCHITECTURE.md, "Direct
    /// manipulation, drag-to-reorder, and undo in the layer-tree editor").
    ///
    /// - Parameter id: The layer's input.
    /// - Returns: Whether that input can contribute frames now.
    func isInputAvailable(_ id: InputID) -> Bool {
        layerInputChoices.contains { $0.id == id }
    }

    /// The sidebar's symbol for an input's kind, or a warning symbol for a
    /// layer whose input is not discovered.
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
        // A media input's symbol comes from the file's content type
        // (ARCHITECTURE.md, "Media inputs and the Library's Media tab").
        case .media:
            LibraryItem.kind(of: mediaItem(forInput: id).flatMap { MediaRegistry.contentType(of: $0.url) }).symbol
        case nil: "exclamationmark.triangle"
        // A kind a later kit adds gets a generic symbol until this mapping
        // names it.
        @unknown default: "questionmark.square.dashed"
        }
    }

    /// Rebuilds every device list from the input registry, never from a
    /// device event's params. The capture plug-ins update the registry before
    /// they emit `device.connected`/`device.disconnected`, so a rebuild cannot
    /// drift, and one code path serves boot and every later change
    /// (ARCHITECTURE.md, "Live device lists in the app").
    func readDeviceLists() async {
        let inputs = await registry.allInputs
        // A device picker asks for a kind ("choose a camera"), so it filters
        // on kind; the two media-role lists filter on what an input produces.
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

    /// Records which inputs declare parameters and hands each the project's
    /// stored values. An input with none stored gets the values it reports
    /// holding (`Input.currentParameters`). One whose settings live only in
    /// the host reports none, so its declared defaults return and the
    /// previous project's tuning does not linger; a device that keeps its
    /// own settings, such as a UVC camera, reports them, so opening a project
    /// never resets its picture (docs/UVC.md). Runs with every device-list
    /// rebuild, because a reconnected device is a fresh input instance.
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

    /// Sets one declared parameter of one input from the settings popover:
    /// stored with the project, and the whole payload applied to the input
    /// live. Gesture-rate, so no event is reported (the control reports its
    /// own `tap`) and the autosave is debounced.
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
    /// label a selection whose device has gone away. Only ever adds, and is
    /// session-scoped: a device name never enters the project document.
    ///
    /// - Parameter inputs: The inputs currently in the registry.
    private func rememberInputNames(from inputs: [any Input]) {
        for input in inputs {
            lastKnownInputNames[input.id] = input.name
        }
    }

    /// Refreshes the device lists after a `device.connected` or
    /// `device.disconnected` event, then reruns both reconfigure passes.
    /// Both are normal events, never errors; every other event is ignored.
    ///
    /// - Parameter event: An event drained from the bus.
    func handleDeviceEvent(_ event: EventBusEvent) async {
        guard event.name == "device.connected" || event.name == "device.disconnected" else { return }
        // A connection is the topology change a silent input needs (a lid
        // opening, a hub re-enumerating), so each is retried on the next pass.
        if event.name == "device.connected" { silentInputs.removeAll() }
        await readDeviceLists()
        await refreshMixerStrips()
        // The video pass stops an input that has left and starts one whose
        // device has returned; both coalesce, so a burst of arrivals (a dock
        // carrying a camera and a display) costs one pass each.
        await reconfigure()
    }

    /// The user-facing name of an input. Falls back to the name discovery
    /// last reported (``lastKnownInputNames``), then the raw identifier,
    /// since an edited layer can outlive its device.
    ///
    /// - Parameter id: The input's stable identifier.
    func inputName(for id: InputID) -> String {
        layerInputChoices.first { $0.id == id }?.name ?? lastKnownInputNames[id] ?? id.rawValue
    }
}
