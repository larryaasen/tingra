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
/// persisted per pane — around the hosted remote view. Uniformity comes
/// from this container, not from asking each author to match it
/// (PLUGINS.md, Decision 5).
struct PlugInPaneSection: View {
    /// The pane.
    let pane: RegisteredPane

    /// The host owning the pane's state.
    let host: AppPlugInHost

    /// The engine model the `tap` is reported through.
    let model: EngineModel

    /// The hosted view's height while open.
    static let expandedHeight: CGFloat = 240

    /// The section.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button {
                let expanded = !host.isExpanded(pane.id)
                model.eventBus.tap(
                    "plugInPane.disclosure", domain: EventDomain(pane.plugIn.rawValue),
                    params: ["pane": .string(pane.id.rawValue), "expanded": .bool(expanded)])
                host.setExpanded(expanded, for: pane.id)
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
                        .rotationEffect(.degrees(host.isExpanded(pane.id) ? 90 : 0))
                }
                .contentShape(.rect)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: pane.descriptor.title))
            if host.isExpanded(pane.id), let plugIn = host.plugIns.first(where: { $0.id == pane.plugIn }) {
                PlugInPaneHost(identity: plugIn.identity, pane: pane.id, sceneID: pane.descriptor.sceneID, host: host)
                    .id(host.paneGenerations[pane.id, default: 0])
                    .frame(height: Self.expandedHeight)
            }
        }
    }
}
