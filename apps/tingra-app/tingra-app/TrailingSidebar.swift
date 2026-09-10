//
//  TrailingSidebar.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import AppKit
import SwiftUI
import TingraEventBus

/// The window's trailing sidebar (GLOSSARY.md, "Sidebar"): a generic
/// container named for where it sits, whose panes today are the layer
/// inspector above and the Library below, split by a draggable divider
/// whose position persists (ARCHITECTURE.md, "Media inputs and the
/// Library's Media tab"; Larry, 2026-09-10: the Library lives at the bottom
/// of the right sidebar behind a draggable splitter, and panes may move
/// between sidebars later without the containers changing).
///
/// A SwiftUI splitter rather than a bridged `NSSplitView`: the AppKit view
/// would buy its autosave at the cost of hosting two SwiftUI trees inside a
/// representable, and a divider with one persisted number is a few dozen
/// lines that stay testable (``LibraryPreferences/clamped(_:in:)``).
struct TrailingSidebar: View {
    /// The engine model both panes read.
    @Bindable var model: EngineModel

    /// The Library's height, seeded from ``LibraryPreferences`` and written
    /// back when a drag ends.
    @State private var libraryHeight: CGFloat

    /// The height when the current drag began, or nil between drags.
    @State private var dragStartHeight: CGFloat?

    /// Where the height persists.
    private let preferences: LibraryPreferences

    /// The sidebar's width bounds: wide enough for two fields beside a label,
    /// never so wide it starves the monitors.
    private static let minimumWidth: CGFloat = 280
    private static let idealWidth: CGFloat = 320
    private static let maximumWidth: CGFloat = 440

    /// Creates the sidebar.
    ///
    /// - Parameters:
    ///   - model: The engine model.
    ///   - preferences: Where the Library's height persists (the standard
    ///     defaults database by default; a throwaway suite under test).
    init(model: EngineModel, preferences: LibraryPreferences = LibraryPreferences()) {
        self.model = model
        self.preferences = preferences
        _libraryHeight = State(initialValue: preferences.height())
    }

    /// The sidebar: the inspector taking what the Library leaves, the
    /// divider, the Library at its clamped height.
    var body: some View {
        GeometryReader { proxy in
            let height = LibraryPreferences.clamped(libraryHeight, in: proxy.size.height)
            VStack(spacing: 0) {
                LayerInspectorColumn(model: model)
                    .frame(maxHeight: .infinity)
                LibrarySplitter { translation in
                    let start = dragStartHeight ?? height
                    dragStartHeight = start
                    // Dragging the divider down shrinks the Library.
                    libraryHeight = LibraryPreferences.clamped(start - translation, in: proxy.size.height)
                } onEnd: {
                    dragStartHeight = nil
                    preferences.setHeight(libraryHeight)
                    model.eventBus.tap(
                        "librarySplitter.drag", domain: .platform, params: ["height": .double(Double(libraryHeight))])
                }
                LibraryView(model: model)
                    .frame(height: height)
            }
        }
        .inspectorColumnWidth(min: Self.minimumWidth, ideal: Self.idealWidth, max: Self.maximumWidth)
    }
}

/// The divider between the inspector and the Library: a hairline with a
/// grabbable band around it, the up-down resize cursor while hovered, and
/// one `tap` per completed drag.
struct LibrarySplitter: View {
    /// Called as the drag moves, with the vertical translation from its
    /// start (positive downward).
    let onChange: (CGFloat) -> Void

    /// Called when the drag ends.
    let onEnd: () -> Void

    /// The grabbable band's height, larger than the hairline it surrounds.
    private static let bandHeight: CGFloat = 7

    /// The divider.
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .frame(height: Self.bandHeight)
            .contentShape(.rect)
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in onChange(value.translation.height) }
                    .onEnded { _ in onEnd() }
            )
            .accessibilityLabel(
                Text(
                    "Drag to resize the Library", comment: "Accessibility label of the splitter above the Library panel"
                ))
    }
}
