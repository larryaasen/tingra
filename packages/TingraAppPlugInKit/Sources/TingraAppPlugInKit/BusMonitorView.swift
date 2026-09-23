//
//  BusMonitorView.swift
//  TingraAppPlugInKit
//
//  Created by Larry Aasen on 2026-09-18.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI

/// A monitor a plug-in's pane puts on a bus (GLOSSARY.md, "Monitor"): the
/// program or the preview, drawn from the app's own frames with no copy —
/// each frame's `IOSurface` becomes a layer's contents, scaled to fit with
/// its aspect kept, over black. It follows the bus while it is on screen
/// and stops when it leaves, so a collapsed pane costs the app nothing.
///
/// ```swift
/// BusMonitorView(connection: connection, bus: .program)
///     .aspectRatio(16 / 9, contentMode: .fit)
/// ```
///
/// A pane that wants the pixels for something else — a scope, an analysis —
/// iterates ``PlugInConnection/frames(_:)`` itself.
public struct BusMonitorView: NSViewRepresentable {
    /// The connection to the app.
    private let connection: PlugInConnection

    /// The bus to show.
    private let bus: FrameBus

    /// Creates a monitor.
    ///
    /// - Parameters:
    ///   - connection: The pane's connection to the app.
    ///   - bus: The bus to show.
    public init(connection: PlugInConnection, bus: FrameBus) {
        self.connection = connection
        self.bus = bus
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        // The layer's contents are the frames', never AppKit's to redraw.
        view.layerContentsRedrawPolicy = .never
        view.layer?.backgroundColor = .black
        view.layer?.contentsGravity = .resizeAspect
        context.coordinator.follow(bus, of: connection, into: view)
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.follow(bus, of: connection, into: view)
    }

    public static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Follows the bus for the view's lifetime, one bus at a time.
    @MainActor
    public final class Coordinator {
        /// The task drawing frames, while following.
        private var task: Task<Void, Never>?

        /// What the task follows, so an update that changes nothing
        /// restarts nothing.
        private var following: (bus: FrameBus, connection: ObjectIdentifier)?

        /// Starts drawing `bus` into `view`, unless it already is.
        ///
        /// - Parameters:
        ///   - bus: The bus to show.
        ///   - connection: The connection to follow it on.
        ///   - view: The layer-backed view whose contents the frames become.
        func follow(_ bus: FrameBus, of connection: PlugInConnection, into view: NSView) {
            let identity = ObjectIdentifier(connection)
            if let following, following.bus == bus, following.connection == identity { return }
            stop()
            following = (bus, identity)
            task = Task { [weak view] in
                for await frame in connection.frames(bus) {
                    guard let view else { break }
                    view.layer?.contents = frame.surface
                }
            }
        }

        /// Stops following.
        func stop() {
            task?.cancel()
            task = nil
            following = nil
        }
    }
}
