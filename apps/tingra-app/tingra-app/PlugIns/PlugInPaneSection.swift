//
//  PlugInPaneSection.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-13.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraAppPlugInKit
import TingraEventBus
import TingraPlugInKit

/// One plug-in pane in the trailing sidebar: the shared chrome — a
/// disclosure header carrying the pane's title and symbol, its expansion
/// persisted per pane, and a close button — around the hosted remote view.
/// Uniformity comes from this container, not from asking each author to
/// match it (PLUGINS.md, Decision 5).
///
/// **Collapse and close are different things.** The chevron collapses the
/// pane to its header and keeps the hosted view alive, so expanding it again
/// shows the pane as it was, with no relaunch and no reload. The close
/// button takes the pane out of the sidebar entirely and ends its session;
/// the View menu's checked item for the pane brings it back
/// (``PlugInCommands``). Before 2026-09-24 the chevron did both — it tore
/// the hosted view down — which is what made collapsing read as closing.
struct PlugInPaneSection: View {
    /// The pane.
    let pane: RegisteredPane

    /// The host owning the pane's state.
    let host: AppPlugInHost

    /// The engine model the `tap` is reported through.
    let model: EngineModel

    /// Whether the pane has been expanded since it appeared. The hosted view
    /// is created on the first expansion — a pane that starts collapsed
    /// launches nothing (PLUGINS.md, Decision 6) — and then kept while
    /// collapsed.
    @State private var hasBeenExpanded = false

    /// The hosted view's height while open.
    static let expandedHeight: CGFloat = 240

    /// The section.
    var body: some View {
        let isExpanded = host.isExpanded(pane.id)
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                disclosureButton(isExpanded: isExpanded)
                closeButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if isExpanded || hasBeenExpanded, let plugIn = host.plugIns.first(where: { $0.id == pane.plugIn }) {
                PlugInPaneHost(identity: plugIn.identity, pane: pane.id, sceneID: pane.descriptor.sceneID, host: host)
                    .id(host.paneGenerations[pane.id, default: 0])
                    .frame(height: isExpanded ? Self.expandedHeight : 0)
                    .clipped()
                    .opacity(isExpanded ? 1 : 0)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
            }
        }
        .onChange(of: isExpanded, initial: true) { _, expanded in
            if expanded { hasBeenExpanded = true }
        }
    }

    /// The header's title, symbol, and chevron, the whole row answering the
    /// click that collapses or expands the pane.
    ///
    /// - Parameter isExpanded: Whether the pane is expanded now.
    /// - Returns: The button.
    private func disclosureButton(isExpanded: Bool) -> some View {
        Button {
            model.eventBus.tap(
                "plugInPane.disclosure", domain: EventDomain(pane.plugIn.rawValue),
                params: ["pane": .string(pane.id.rawValue), "expanded": .bool(!isExpanded)])
            withAnimation(.snappy) {
                host.setExpanded(!isExpanded, for: pane.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pane.descriptor.systemImage)
                    .foregroundStyle(.secondary)
                Text(verbatim: pane.descriptor.title)
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: pane.descriptor.title))
        .help(
            isExpanded
                ? Text("Collapse", comment: "Tooltip on a plug-in pane header that collapses the pane to its header")
                : Text("Expand", comment: "Tooltip on a collapsed plug-in pane header that expands the pane"))
    }

    /// The close button at the header's trailing end, taking the pane out of
    /// the sidebar until the View menu brings it back.
    private var closeButton: some View {
        Button {
            model.eventBus.tap(
                "plugInPane.close", domain: EventDomain(pane.plugIn.rawValue),
                params: ["pane": .string(pane.id.rawValue)])
            withAnimation(.snappy) {
                host.setClosed(true, for: pane.id)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            Text(
                "Close \(pane.descriptor.title)",
                comment: "Accessibility label of a plug-in pane's close button; the argument is the pane's title")
        )
        .help(
            Text(
                "Close \(pane.descriptor.title) — show it again from the View menu",
                comment: "Tooltip on a plug-in pane's close button; the argument is the pane's title"))
    }
}
