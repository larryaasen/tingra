//
//  EngineModel+MonitorOverlays.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreGraphics
import Foundation
import TingraComposition
import TingraEventBus
import TingraMonitorPlugIns
import TingraPlugInKit

/// Monitor overlays: which are on for each monitor, and their parameters.
extension EngineModel {
    /// Replaces the catalog of registered monitor overlays: what the engine
    /// start calls once the plug-ins have activated, and what a test calls
    /// with its own providers.
    ///
    /// - Parameter providers: The registered providers, in any order.
    func fillMonitorOverlayCatalog(with providers: [any MonitorOverlayProvider]) {
        monitorOverlayCatalog = MonitorOverlayCatalog(providers: providers)
    }

    /// Whether a monitor overlay is on for a monitor.
    ///
    /// - Parameters:
    ///   - id: The overlay.
    ///   - target: The monitor.
    /// - Returns: Whether the project shows it there.
    func isMonitorOverlayOn(_ id: MonitorOverlayID, on target: MonitorOverlayTarget) -> Bool {
        effectiveMonitorOverlays[target.monitor].contains(id)
    }

    /// The overlays on a monitor, in the order they were turned on, those
    /// whose plug-in is not loaded included.
    ///
    /// - Parameter target: The monitor.
    /// - Returns: The overlay ids.
    func monitorOverlayIDs(on target: MonitorOverlayTarget) -> [MonitorOverlayID] {
        effectiveMonitorOverlays[target.monitor]
    }

    /// Whether a monitor overlay has anything to show on a monitor; the
    /// Overlays submenus disable one that does not. Asks about the kind of
    /// monitor and, for program and preview, the program format; an input
    /// tile's or the layer monitor's canvas varies, so its draw checks that.
    ///
    /// - Parameters:
    ///   - provider: The overlay's provider.
    ///   - target: The monitor.
    /// - Returns: Whether it can draw there.
    func isMonitorOverlayAvailable(_ provider: any MonitorOverlayProvider, on target: MonitorOverlayTarget) -> Bool {
        guard provider.isAvailable(on: target.monitor) else { return false }
        guard target.showsProgramCanvas else { return true }
        return provider.isAvailable(onCanvas: CGSize(width: format.width, height: format.height))
    }

    /// Turns a monitor overlay on or off for a monitor. Saved with the
    /// project and reported as `monitorOverlay.changed`, but never undoable:
    /// undoing a layer move must not turn a guide off (PLUGINS.md, Decision
    /// 55). The calling menu item reports its own `tap` first.
    ///
    /// - Parameters:
    ///   - id: The overlay.
    ///   - target: The monitor.
    ///   - isOn: Whether the overlay should be shown.
    func setMonitorOverlay(_ id: MonitorOverlayID, on target: MonitorOverlayTarget, isOn: Bool) {
        guard isMonitorOverlayOn(id, on: target) != isOn else { return }
        var settings = effectiveMonitorOverlays
        settings[target.monitor] = Self.toggled(settings[target.monitor], id, isOn: isOn)
        monitorOverlaySettings = settings
        eventBus.event(
            "monitorOverlay.changed", domain: .composition,
            params: ["monitor": target.eventValue, "overlay": .string(id.rawValue), "isOn": .bool(isOn)])
        scheduleAutosave()
    }

    /// The overlays one monitor draws, made from the catalog with the
    /// project's values: what `MonitorTile` hands its monitor. One whose
    /// plug-in is not loaded is left out but stays in the project.
    ///
    /// - Parameters:
    ///   - target: The monitor.
    ///   - tally: The monitor's tally, or nil for the target's default
    ///     (``MonitorOverlayTarget/defaultTally``).
    ///   - input: An input tile's input, whose strip its meters read; nil
    ///     for every other monitor.
    /// - Returns: The monitor's overlays, in drawing order.
    func monitorOverlayLineup(
        for target: MonitorOverlayTarget, tally: MonitorOverlayContext.Tally? = nil, input: InputID? = nil
    ) -> MonitorOverlayLineup {
        let settings = effectiveMonitorOverlays
        var lineup = MonitorOverlayLineup(
            entries: monitorOverlayCatalog.overlays(for: settings[target.monitor], parameters: settings.parameters),
            monitor: target.monitor, tally: tally ?? target.defaultTally)
        if lineup.usesAudioLevels, let subject = meterSubject(for: target, input: input) {
            lineup.meters = MonitorOverlayMeters(relay: meterRelay, subject: subject)
        }
        return lineup
    }

    /// Whose levels a monitor's meters read: the master on program, an
    /// input tile's input, the selected layer's input on the layer monitor,
    /// and nothing on preview, which has no sound of its own.
    ///
    /// - Parameters:
    ///   - target: The monitor.
    ///   - input: The input an input tile shows.
    /// - Returns: The meter subject, or nil for none.
    private func meterSubject(for target: MonitorOverlayTarget, input: InputID?) -> PeakSubject? {
        switch target {
        case .program: .master
        case .preview: nil
        case .input: input.map { .strip($0) }
        case .layer: selectedLayer.map { .strip($0.layer.input) }
        }
    }

    /// One monitor overlay's stored values: what Overlay Settings edits and
    /// every monitor draws it with. Empty until a value is changed, when the
    /// overlay draws at its declared defaults.
    ///
    /// - Parameter id: The overlay.
    /// - Returns: The values, keyed by declared parameter key.
    func monitorOverlayParameterValues(for id: MonitorOverlayID) -> [String: JSONValue] {
        effectiveMonitorOverlays.parameters[id.rawValue] ?? [:]
    }

    /// Changes one of a monitor overlay's values, on every monitor it is
    /// drawn on (PLUGINS.md, Decision 55). Saved with the project and not
    /// undoable, like turning an overlay on. The calling control reports its
    /// own `tap` when the change settles, not on every step of a drag.
    ///
    /// - Parameters:
    ///   - value: The new value.
    ///   - key: The declared parameter key.
    ///   - id: The overlay.
    func setMonitorOverlayParameter(_ value: JSONValue, forKey key: String, ofOverlay id: MonitorOverlayID) {
        var settings = effectiveMonitorOverlays
        var values = settings.parameters[id.rawValue] ?? [:]
        guard values[key] != value else { return }
        values[key] = value
        settings.parameters[id.rawValue] = values
        monitorOverlaySettings = settings
        scheduleAutosave()
    }

    /// Returns a monitor overlay to its declared defaults by forgetting its
    /// stored values. Reports `monitorOverlay.reset`.
    ///
    /// - Parameter id: The overlay.
    func resetMonitorOverlayParameters(ofOverlay id: MonitorOverlayID) {
        guard effectiveMonitorOverlays.parameters[id.rawValue] != nil else { return }
        var settings = effectiveMonitorOverlays
        settings.parameters[id.rawValue] = nil
        monitorOverlaySettings = settings
        eventBus.event("monitorOverlay.reset", domain: .composition, params: ["overlay": .string(id.rawValue)])
        scheduleAutosave()
    }

    /// Whether a monitor shows its picture mirrored: Flip Horizontal is on
    /// there and its plug-in is loaded. The layer handles mirror with the
    /// picture, so a drag still moves the layer the way the pointer goes.
    ///
    /// - Parameter target: The monitor.
    /// - Returns: Whether the picture there is mirrored.
    func isMonitorMirrored(_ target: MonitorOverlayTarget) -> Bool {
        let flip = FlipHorizontalOverlayProvider.overlayID
        return isMonitorOverlayOn(flip, on: target) && monitorOverlayCatalog.provider(withID: flip) != nil
    }

    /// A monitor's overlay list with one overlay added at the end or removed.
    ///
    /// - Parameters:
    ///   - list: The list.
    ///   - id: The overlay.
    ///   - isOn: Whether it should be in the list.
    /// - Returns: The new list.
    private static func toggled(_ list: [MonitorOverlayID], _ id: MonitorOverlayID, isOn: Bool) -> [MonitorOverlayID] {
        isOn ? (list.contains(id) ? list : list + [id]) : list.filter { $0 != id }
    }
}
