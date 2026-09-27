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
import TingraPlugInKit

/// The Streaming settings pane's destination list: every destination the
/// program fans out to, one form section each, then an Add Destination
/// section (ARCHITECTURE.md, "Multiple destinations").
///
/// **One section per destination rather than one row**, which is the change
/// the move into the settings window forced (2026-09-08). The main window's
/// streaming panel drew each destination as a single line — toggle, name,
/// URL, key, state, remove — across a column as wide as the window; a
/// settings form is a third of that, and the same line left the URL field a
/// sliver. A section per destination gives every field its own labeled row,
/// the shape System Settings gives a list of configured things, and the
/// section's header carries the destination's name so the list still reads
/// at a glance.
///
/// Rows lock while streaming — v1 adds and removes destinations between runs,
/// never mid-stream — and each section shows its own live state, so one
/// destination reconnecting is visible without implying the whole program is
/// off air.
///
/// **Add Destination is a pull-down menu** (2026-09-26): the destination
/// templates the streaming outputs offer — Twitch, YouTube, and the rest, by
/// name — then Custom Server, which adds the blank destination the button
/// used to. A template fills in the name and URL, so the one thing left is
/// the stream key, and the cursor goes straight to it (DESTINATIONS.md,
/// "Destination templates").
///
/// Not a `Form` itself: it contributes sections to the pane's form, so the
/// pane can place its status section after them.
struct DestinationListView: View {
    /// The engine model owning the destinations and the stream session.
    let model: EngineModel

    /// Which destination's stream key field has the keyboard focus, if any —
    /// held here, above the sections, so adding a destination from a
    /// template can move the cursor into the new section's key field.
    @FocusState private var focusedKeyField: ProjectDestinationID?

    var body: some View {
        ForEach(model.destinations) { destination in
            DestinationSection(model: model, destination: destination, focusedKeyField: $focusedKeyField)
        }

        Section {
            Menu {
                ForEach(model.destinationTemplates, id: \.self) { template in
                    // A service's name is a proper noun, the same in every
                    // language, so it is shown as given.
                    Button {
                        model.eventBus.tap(
                            "destinationAddTemplate.menuItem",
                            domain: .output,
                            params: ["template": .string(template.id)]
                        )
                        focusedKeyField = model.addDestination(from: template)
                    } label: {
                        Text(verbatim: template.name)
                    }
                }
                if !model.destinationTemplates.isEmpty {
                    Divider()
                }
                Button {
                    model.eventBus.tap("destinationAddCustom.menuItem", domain: .output)
                    model.addDestination()
                } label: {
                    Text(
                        "Custom Server",
                        comment:
                            "Add Destination menu item that adds a blank destination for a server of the operator's own"
                    )
                }
            } label: {
                Label {
                    Text("Add Destination", comment: "Button that adds a stream destination")
                } icon: {
                    Image(systemName: "plus")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(model.isStreaming)
        } footer: {
            if model.destinations.isEmpty {
                Text(
                    "No destinations yet. Add one to stream.",
                    comment: "Empty state under the Streaming settings pane's destination list"
                )
            }
        }
    }
}

/// One destination's section: an enable switch, name, URL, stream key, its
/// live state while streaming, and Remove Destination, under a header naming
/// it.
///
/// The name and URL are view-local `@State` seeded from the model, so typing
/// is smooth and a half-typed URL never round-trips through the document. The
/// key is view-local too and is never observable model state: it is filed in
/// secure storage **as it is typed** (``EngineModel/setStreamKey(_:for:)``)
/// and prefilled from there, because the toolbar's Start Streaming — in
/// another window now — reads each key back from the Keychain at the click
/// (ARCHITECTURE.md, "Streaming the program").
///
/// **Seeding must not write back**, which is what the equality guards on the
/// three `onChange` handlers are for. Adopting the saved values moves each
/// field off its empty initial value, and `onChange` cannot tell that from
/// typing — so without the guards, every launch pushed the destination's own
/// name and URL back into the model, scheduling an autosave, clearing a
/// stream-status banner, and mutating observable state from inside a view
/// update. That last one is what surfaced it: once the sidebar listed
/// destinations too, the write invalidated its `List` mid-update and AppKit
/// reported a reentrant operation in the table's delegate. The key's guard
/// compares against the value last read from or filed in secure storage,
/// since the model deliberately holds no key to compare with.
///
/// **The header keeps one identity while the name is typed** — see
/// ``headerTitle`` for why focus depends on it. The same reason puts the
/// stream-key link in a row rather than a footer: a row inserted as the URL
/// completes leaves the section, and the cursor in it, alone.
///
/// **Destination templates reach the section two ways** (DESTINATIONS.md,
/// "What the app does with it"): the URL field suggests them as it is typed,
/// and a URL that matches one — chosen, typed, or pasted — names a blank
/// destination after the service and offers a link to where its stream key
/// is found.
private struct DestinationSection: View {
    /// The engine model the edits land in.
    let model: EngineModel

    /// The destination this section edits.
    let destination: DestinationEdit

    /// Which destination's key field has the focus — the list's, so adding
    /// a destination from a template can put the cursor in this section's
    /// key field.
    var focusedKeyField: FocusState<ProjectDestinationID?>.Binding

    /// Opens a service's stream-key page in the operator's browser.
    @Environment(\.openURL) private var openURL

    /// The name field's working text.
    @State private var name = ""

    /// The URL field's working text.
    @State private var urlText = ""

    /// The stream-key field's working text.
    @State private var streamKey = ""

    /// The key as last read from or filed in secure storage — what the key
    /// field's `onChange` compares against, so seeding the field and the
    /// echo of a write file nothing.
    @State private var persistedKey = ""

    var body: some View {
        Section {
            Toggle(isOn: enabledBinding) {
                Text("Stream to this destination", comment: "Label of a destination's enable switch")
            }
            .disabled(model.isStreaming)
            .help(Text("Include this destination when streaming", comment: "Tooltip for the destination toggle"))

            TextField(
                text: $name,
                prompt: Text("Name", comment: "Name text field label — for a shot, a preset, or a destination")
            ) {
                Text("Name", comment: "Name text field label — for a shot, a preset, or a destination")
            }
            .disabled(model.isStreaming)
            .onChange(of: name) { _, newValue in
                guard newValue != destination.name else { return }
                model.setDestinationName(newValue, for: destination.id)
            }
            // The field is seeded once, so a name the model sets — the
            // template's, adopted as its URL is completed — is followed here;
            // the name handler's guard then files nothing back.
            .onChange(of: destination.name) { _, newValue in
                if newValue != name { name = newValue }
            }
            .task(id: destination.id) {
                // Adopt this destination's saved values, including its key
                // from secure storage — keyed by id, so an edited URL keeps
                // its key.
                name = destination.name
                urlText = destination.urlText
                persistedKey = model.storedStreamKey(for: destination.id) ?? ""
                streamKey = persistedKey
            }

            TextField(
                text: $urlText,
                prompt: Text("rtmp://server/app", comment: "Placeholder for the destination URL field")
            ) {
                Text("Destination", comment: "Destination URL field label")
            }
            .disabled(model.isStreaming)
            .textInputSuggestions(model.destinationTemplates.suggestions(forURLText: urlText), id: \.self) { template in
                // The service's name, then the URL the suggestion fills in.
                (Text(verbatim: template.name)
                    + Text(verbatim: "  \(template.url.absoluteString)").foregroundStyle(.secondary))
                    .textInputCompletion(template.url.absoluteString)
            }
            .onChange(of: urlText) { _, newValue in
                guard newValue != destination.urlText else { return }
                model.setDestinationURL(newValue, for: destination.id)
                // A URL that is a service's — however it arrived — names a
                // destination the operator has not named yet.
                if name.trimmingCharacters(in: .whitespaces).isEmpty,
                    let template = model.destinationTemplates.template(matchingURLText: newValue)
                {
                    name = template.name
                }
            }

            SecureField(
                text: $streamKey,
                prompt: Text("Stream key", comment: "Placeholder for the stream key field")
            ) {
                Text("Stream key", comment: "Stream key field label")
            }
            .disabled(model.isStreaming)
            .focused(focusedKeyField, equals: destination.id)
            .onChange(of: streamKey) { _, newValue in
                guard newValue != persistedKey else { return }
                persistedKey = newValue
                model.setStreamKey(newValue, for: destination.id)
            }

            if let template = matchedTemplate, let page = template.streamKeyPageURL {
                Button {
                    model.eventBus.tap(
                        "destinationStreamKeyPage.button",
                        domain: .output,
                        params: ["template": .string(template.id)]
                    )
                    openURL(page)
                } label: {
                    Text(
                        "Get your stream key from \(template.name)",
                        comment:
                            "Link under a destination's stream key field to the service's stream key page; the argument is the service's name, e.g. Twitch"
                    )
                }
                .buttonStyle(.link)
            }

            if model.destinationStates[destination.id] != nil {
                LabeledContent {
                    destinationStateLabel
                } label: {
                    Text(
                        "Status", comment: "Streaming and Recording settings: label of the row showing the live status")
                }
            }

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
            .buttonStyle(.borderless)
            .disabled(model.isStreaming)
        } header: {
            Text(headerTitle)
        }
    }

    /// The template this destination's URL, as typed, already is — the
    /// service whose stream-key page the section links to — or nil.
    private var matchedTemplate: DestinationTemplate? {
        model.destinationTemplates.template(matchingURLText: urlText)
    }

    /// The section header's title: the destination's name, or a placeholder
    /// while it is blank.
    ///
    /// **One `Text` whose string changes, never an `if`/`else` of two**,
    /// because the header follows the name as it is typed. Two branches give
    /// the header a different identity the moment a new destination's name
    /// goes from blank to its first character (or back), and the grouped
    /// form rebuilds the whole section for that — tearing down the Name field
    /// under the operator's cursor, so focus dropped after one keystroke.
    private var headerTitle: String {
        guard destination.name.isEmpty else { return destination.name }
        return String(
            localized: "Untitled Destination",
            comment: "Streaming settings: heading over a destination whose name is blank")
    }

    /// The enable switch's binding, reading the model and writing through it
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
