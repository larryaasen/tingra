//
//  DestinationListView.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-07-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import SwiftUI
import TingraComposition
import TingraEventBus

/// The streaming panel's destination list: every destination the program
/// fans out to, each with its name, URL, stream key, and an enable toggle
/// (ARCHITECTURE.md, "Multiple destinations").
///
/// Rows lock while streaming — v1 adds and removes destinations between runs,
/// never mid-stream — and each shows its own live state, so one destination
/// reconnecting is visible without implying the whole program is off air.
struct DestinationListView: View {
    /// The engine model owning the destinations and the stream session.
    let model: EngineModel

    /// Each destination's stream-key field text, by destination id — owned by
    /// the streaming panel, which collects every row's key at Start. Never
    /// model state: a key goes only to secure storage.
    @Binding var keys: [ProjectDestinationID: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.destinations.isEmpty {
                Text(
                    "No destinations yet. Add one to stream.",
                    comment: "Empty state under the streaming panel's destination list"
                )
                .foregroundStyle(.secondary)
                .font(.callout)
            }

            ForEach(model.destinations) { destination in
                DestinationRow(
                    model: model,
                    destination: destination,
                    streamKey: keyBinding(for: destination.id)
                )
            }

            Button {
                model.eventBus.tap("destinationAdd.button", domain: .output)
                model.addDestination()
            } label: {
                Label {
                    Text("Add Destination", comment: "Button that adds a stream destination")
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isStreaming)
        }
    }

    /// One destination's slot in the panel's key collection, reading an
    /// absent entry as the empty string (a destination that needs no key, or
    /// one whose row has not seeded yet).
    ///
    /// - Parameter id: The destination the field belongs to.
    /// - Returns: A binding into ``keys``.
    private func keyBinding(for id: ProjectDestinationID) -> Binding<String> {
        Binding(
            get: { keys[id] ?? "" },
            set: { keys[id] = $0 }
        )
    }
}

/// One destination's row: enable toggle, name, URL, stream key, live state,
/// and a remove button.
///
/// The name and URL are view-local `@State` seeded from the model, so typing
/// is smooth and a half-typed URL never round-trips through the document. The
/// key is bound to the panel's collection and is never observable model
/// state: it goes straight to secure storage at Start and is prefilled from
/// there (ARCHITECTURE.md, "Streaming the program").
///
/// **Seeding must not write back**, which is what the equality guards on the
/// two `onChange` handlers are for. Adopting the saved values moves each field
/// off its empty initial value, and `onChange` cannot tell that from typing —
/// so without the guards, every launch pushed the destination's own name and
/// URL back into the model, scheduling an autosave, clearing a stream-status
/// banner, and mutating observable state from inside a view update. That last
/// one is what surfaced it: once the sidebar listed destinations too, the
/// write invalidated its `List` mid-update and AppKit reported a reentrant
/// operation in the table's delegate.
private struct DestinationRow: View {
    /// The engine model the edits land in.
    let model: EngineModel

    /// The destination this row edits.
    let destination: DestinationEdit

    /// This destination's stream-key field text, owned by the panel.
    @Binding var streamKey: String

    /// The name field's working text.
    @State private var name = ""

    /// The URL field's working text.
    @State private var urlText = ""

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: enabledBinding) {
                Text("Stream to this destination", comment: "Accessibility label for a destination's enable toggle")
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(model.isStreaming)
            .help(Text("Include this destination when streaming", comment: "Tooltip for the destination toggle"))

            TextField(
                text: $name,
                prompt: Text("Name", comment: "Name text field label — for a shot, a preset, or a destination")
            ) {
                Text("Name", comment: "Name text field label — for a shot, a preset, or a destination")
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .disabled(model.isStreaming)
            .onChange(of: name) { _, newValue in
                guard newValue != destination.name else { return }
                model.setDestinationName(newValue, for: destination.id)
            }

            TextField(
                text: $urlText,
                prompt: Text("rtmp://server/app", comment: "Placeholder for the destination URL field")
            ) {
                Text("Destination", comment: "Destination URL field label")
            }
            .textFieldStyle(.roundedBorder)
            .disabled(model.isStreaming)
            .onChange(of: urlText) { _, newValue in
                guard newValue != destination.urlText else { return }
                model.setDestinationURL(newValue, for: destination.id)
            }

            SecureField(
                text: $streamKey,
                prompt: Text("Stream key", comment: "Placeholder for the stream key field")
            ) {
                Text("Stream key", comment: "Stream key field label")
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 140)
            .disabled(model.isStreaming)

            destinationStateLabel
                .frame(width: 130, alignment: .trailing)

            Button(role: .destructive) {
                model.eventBus.tap("destinationRemove.button", domain: .output)
                model.removeDestination(destination.id)
            } label: {
                Label {
                    Text("Remove Destination", comment: "Button that deletes a stream destination")
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.isStreaming)
        }
        .task(id: destination.id) {
            // Adopt this destination's saved values, including its key from
            // secure storage — keyed by id, so an edited URL keeps its key.
            name = destination.name
            urlText = destination.urlText
            streamKey = model.storedStreamKey(for: destination.id) ?? ""
        }
    }

    /// The enable toggle's binding, reading the model and writing through it
    /// so the change autosaves like any other destination edit.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { destination.isEnabled },
            set: { newValue in
                model.eventBus.tap(
                    "destinationEnabled.toggle",
                    domain: .output,
                    params: ["enabled": .bool(newValue)]
                )
                model.setDestinationEnabled(newValue, for: destination.id)
            }
        )
    }

    /// This destination's own live state while streaming: its stats when
    /// delivering, its reconnect progress when it alone is down, and why it
    /// is not delivering when it is not. Blank when the program is off air.
    @ViewBuilder private var destinationStateLabel: some View {
        switch model.destinationStates[destination.id] {
        case .live:
            if let stats = model.destinationStats[destination.id] {
                Text(verbatim: "\(stats.bitrateKbps) kbps · \(stats.fps) fps")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .monospacedDigit()
            } else {
                Text("Live", comment: "Per-destination state: this destination is publishing")
                    .foregroundStyle(.red)
                    .font(.caption.weight(.semibold))
            }
        case .reconnecting(let attempt, let maxAttempts):
            (Text("Reconnecting…", comment: "Stream status: a reconnect attempt is in flight")
                + Text(verbatim: " \(attempt)/\(maxAttempts)"))
                .foregroundStyle(.orange)
                .font(.caption)
        case .rejected:
            Text("Refused", comment: "Per-destination state: the destination refused the connection at start")
                .foregroundStyle(.red)
                .font(.caption)
        case .lost:
            Text("Lost", comment: "Per-destination state: the destination dropped and did not recover")
                .foregroundStyle(.red)
                .font(.caption)
        case nil:
            EmptyView()
        }
    }
}
