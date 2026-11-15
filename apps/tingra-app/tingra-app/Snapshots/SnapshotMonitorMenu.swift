//
//  SnapshotMonitorMenu.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraEventBus

/// A monitor's **Save Snapshot** context menu and the badge that answers it —
/// one modifier every monitor wears, never a copy per surface
/// (ARCHITECTURE.md, "Snapshots"): the program and preview monitors in the
/// main window and the multiview window, every multiview tile, and the layer
/// monitor.
///
/// A context menu only: a multiview tile stays **inert to clicks**
/// (``InputGridView``) — a click there must never stage a guessed shot one
/// click from air — and a context menu that writes a file changes nothing on
/// air. The badge is the monitor's answer, bottom center (top trailing
/// belongs to the faded-to-black badge), whether the request came from here
/// or from the menu bar.
///
/// Every monitor's menu also carries **Overlays**, after Save Snapshot
/// (``MonitorOverlayMenu``; PLUGINS.md, Decision 57): the same one context
/// menu, since a second `contextMenu` on the same view would replace this
/// one rather than add to it. A multiview tile's items change the list
/// every input tile shares.
struct SnapshotMonitorMenu: ViewModifier {
    /// The engine model the menu saves through and reports its `tap` to.
    let model: EngineModel

    /// The monitor this is.
    let subject: SnapshotSubject

    /// The menu item's tap name — unique per surface.
    let tapName: String

    /// Extra tap params — a tile's input id and name.
    let tapParams: [String: EventValue]?

    /// The monitor whose overlays the Overlays submenu changes.
    private var target: MonitorOverlayTarget {
        MonitorOverlayTarget(subject: subject)
    }

    /// The monitor, with its badge and its menu.
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let feedback = model.snapshotFeedback, feedback.subject == subject {
                    SnapshotBadge(feedback: feedback)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.snapshotFeedback?.subject == subject)
            .contextMenu {
                Button {
                    model.eventBus.tap(tapName, domain: .composition, params: tapParams)
                    Task { await model.saveSnapshot(subject) }
                } label: {
                    Text("Save Snapshot", comment: "Monitor context menu item saving its picture as an image file")
                }
                Divider()
                MonitorOverlayMenu(
                    model: model, target: target, tapName: "\(target.rawValue)MonitorOverlay.menuItem",
                    title: Text(
                        "Overlays",
                        comment: "Monitor context menu: the submenu of monitor overlays drawn for the operator only"
                    ))
            }
    }
}

extension View {
    /// Gives a monitor the Save Snapshot context menu and its badge
    /// (``SnapshotMonitorMenu``).
    ///
    /// - Parameters:
    ///   - model: The engine model.
    ///   - subject: Which monitor this is.
    ///   - tapName: The menu item's tap name.
    ///   - tapParams: Extra tap params, or nil.
    /// - Returns: The monitor with its menu.
    func snapshotMenu(
        model: EngineModel, subject: SnapshotSubject, tapName: String, tapParams: [String: EventValue]? = nil
    ) -> some View {
        modifier(SnapshotMonitorMenu(model: model, subject: subject, tapName: tapName, tapParams: tapParams))
    }
}

/// The capsule a monitor wears for a moment after a snapshot request, in
/// the monitor badges' own style.
struct SnapshotBadge: View {
    /// What the request came to.
    let feedback: SnapshotFeedback

    /// The badge.
    var body: some View {
        feedback.title
            .font(.caption.weight(.semibold))
            .padding(6)
            .background(feedback.tint.opacity(0.85), in: .capsule)
            .foregroundStyle(.white)
            .padding(8)
            .help(feedback.help)
    }
}
