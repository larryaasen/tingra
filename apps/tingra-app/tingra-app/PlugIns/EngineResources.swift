//
//  EngineResources.swift
//  TingraApp
//
//  Created by Larry Aasen on 2026-09-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Observation
import Synchronization
import TingraComposition
import TingraPlugInKit

/// A resource rendered from the engine model's observable state: the
/// document is a snapshot closure run on the main actor, and the change
/// signals come from observation tracking of exactly what that closure
/// reads — so a plug-in following `tingra://program` is woken by a take and
/// never by a meter, and nothing polls (PLUGINS.md, "Phase 2 — seams into
/// the engine"). `nonisolated`: the MCP session reads it from its own
/// actor, and only the snapshot hops to the main actor.
nonisolated final class ModelResource: Resource, Sendable {
    let uri: String
    let name: String
    let title: String
    let description: String

    /// Renders the document from the model, on the main actor.
    private let snapshot: @MainActor @Sendable () -> JSONValue

    /// Creates a resource over a snapshot of the model.
    ///
    /// - Parameters:
    ///   - uri: The resource's URI.
    ///   - name: The machine-friendly name.
    ///   - title: The human-facing title.
    ///   - description: What the document carries.
    ///   - snapshot: Renders the document from the model.
    init(
        uri: String, name: String, title: String, description: String,
        snapshot: @escaping @MainActor @Sendable () -> JSONValue
    ) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.snapshot = snapshot
    }

    func read() async throws -> JSONValue {
        await snapshot()
    }

    /// One signal per change of the rendered document: the task re-renders
    /// after each change to anything the snapshot read and signals only when
    /// the document differs, so a write that lands the same value stays
    /// silent. The newest signal is kept; a subscriber re-reads once.
    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let snapshot = self.snapshot
            let task = Task { @MainActor in
                var previous = snapshot()
                while !Task.isCancelled {
                    await ObservedChange.next { _ = snapshot() }
                    guard !Task.isCancelled else { break }
                    let current = snapshot()
                    guard current != previous else { continue }
                    previous = current
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Waits for the next change to whatever a main-actor read touches — the
/// one-shot `withObservationTracking` turned into something a loop can
/// await, and cancellable, so a follower that stops leaves no task parked
/// until the model next moves.
nonisolated enum ObservedChange {
    /// Runs `read` under observation tracking and returns once any
    /// observable property it read changes, or the task is cancelled.
    ///
    /// - Parameter read: The read to track, on the main actor.
    @MainActor
    static func next(of read: @MainActor () -> Void) async {
        let waiter = Waiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter.arm(continuation)
                withObservationTracking(read) {
                    waiter.fire()
                }
                // A task cancelled before the handler was armed would wait
                // forever; the handler ran first and found nothing to fire.
                if Task.isCancelled { waiter.fire() }
            }
        } onCancel: {
            waiter.fire()
        }
    }

    /// Resumes a continuation exactly once, from whichever of the change
    /// callback and the cancellation handler comes first.
    private final class Waiter: Sendable {
        /// The continuation, until fired.
        private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

        /// Holds the continuation to fire.
        func arm(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation.withLock { $0 = continuation }
        }

        /// Resumes the continuation if it has not been already.
        func fire() {
            let armed = continuation.withLock { armed -> CheckedContinuation<Void, Never>? in
                defer { armed = nil }
                return armed
            }
            armed?.resume()
        }
    }
}

/// The resources the app serves over every plug-in connection, rendered
/// from the engine model: what a plug-in (or, through the same protocol, an
/// agent) can observe of the engine. Value types and identifiers only —
/// never the compositor, the mixer, or a registry (PLUGINS.md, Phase 2).
/// Every key is a scripting contract: camelCase, append-only.
enum EngineResources {
    /// `tingra://session` — the stream and the recording.
    static let sessionURI = "tingra://session"

    /// `tingra://program` — presets, shots, the buses, tally, fade to black.
    static let programURI = "tingra://program"

    /// `tingra://inputs` — the inputs the engine knows.
    static let inputsURI = "tingra://inputs"

    /// The three resources over `model`.
    static func all(for model: EngineModel) -> [ModelResource] {
        [session(of: model), program(of: model), inputs(of: model)]
    }

    /// The session resource: stream status with each destination's state and
    /// counters, and recording status.
    static func session(of model: EngineModel) -> ModelResource {
        ModelResource(
            uri: sessionURI, name: "session", title: "Session",
            description:
                "The stream and the recording: 'stream.state' (idle, starting, live, reconnecting, stopped, error) "
                + "with the delivery counters and each destination's own state, and 'recording.state' (idle, "
                + "starting, recording, finalizing, error) with the file being written. Changes whenever either does."
        ) { [weak model] in
            guard let model else { return .object([:]) }
            return sessionValue(of: model)
        }
    }

    /// The program resource: presets and the active one, the active preset's
    /// shots, what is on program and preview, the tally, and fade to black.
    static func program(of model: EngineModel) -> ModelResource {
        ModelResource(
            uri: programURI, name: "program", title: "Program",
            description:
                "What is on air: the presets and the active one, the active preset's shots with their ids (what "
                + "shot_take and preview_set take), 'programShot' and 'previewShot', the input ids contributing to "
                + "each ('programInputs', 'previewInputs' — the tally), and 'fadedToBlack'. Changes on every take, "
                + "stage, edit, and fade."
        ) { [weak model] in
            guard let model else { return .object([:]) }
            return programValue(of: model)
        }
    }

    /// The inputs resource: every input the engine knows, by kind and media.
    static func inputs(of model: EngineModel) -> ModelResource {
        ModelResource(
            uri: inputsURI, name: "inputs", title: "Inputs",
            description:
                "Every input the engine knows: id, name, kind (camera, microphone, display, generator, media), and "
                + "the media it produces ('video', 'audio'); a media input carries its file 'path'. Changes as "
                + "devices connect and disconnect and as media is added and removed."
        ) { [weak model] in
            guard let model else { return .object([:]) }
            return inputsValue(of: model)
        }
    }

    // MARK: - Documents

    /// The `tingra://session` document.
    static func sessionValue(of model: EngineModel) -> JSONValue {
        var stream: [String: JSONValue] = [:]
        switch model.streamStatus {
        case .idle: stream["state"] = .string("idle")
        case .starting: stream["state"] = .string("starting")
        case .live: stream["state"] = .string("live")
        case .reconnecting(let attempt, let maxAttempts):
            stream["state"] = .string("reconnecting")
            stream["attempt"] = .int(attempt)
            stream["maxAttempts"] = .int(maxAttempts)
        case .stopped: stream["state"] = .string("stopped")
        case .error(let message):
            stream["state"] = .string("error")
            stream["message"] = .string(message)
        }
        if let stats = model.streamStats {
            stream["bitrateKbps"] = .int(stats.bitrateKbps)
            stream["fps"] = .int(stats.fps)
        }
        stream["destinations"] = .array(
            model.destinations.map { destination in
                var leg: [String: JSONValue] = [
                    "id": .string(destination.id.rawValue),
                    "name": .string(destination.name),
                    "url": .string(destination.urlText),
                    "enabled": .bool(destination.isEnabled),
                ]
                switch model.destinationStates[destination.id] {
                case .live: leg["state"] = .string("live")
                case .reconnecting(let attempt, let maxAttempts):
                    leg["state"] = .string("reconnecting")
                    leg["attempt"] = .int(attempt)
                    leg["maxAttempts"] = .int(maxAttempts)
                case .rejected: leg["state"] = .string("rejected")
                case .lost: leg["state"] = .string("lost")
                case nil: break
                }
                if let stats = model.destinationStats[destination.id] {
                    leg["bitrateKbps"] = .int(stats.bitrateKbps)
                    leg["fps"] = .int(stats.fps)
                }
                return .object(leg)
            })

        var recording: [String: JSONValue] = [:]
        switch model.recordingStatus {
        case .idle: recording["state"] = .string("idle")
        case .starting: recording["state"] = .string("starting")
        case .recording: recording["state"] = .string("recording")
        case .finalizing: recording["state"] = .string("finalizing")
        case .error(let message):
            recording["state"] = .string("error")
            recording["message"] = .string(message)
        }
        if let url = model.recordingURL {
            recording["path"] = .string(url.path(percentEncoded: false))
            recording["container"] = .string(url.pathExtension)
        }
        if let startedAt = model.recordingStartedAt {
            recording["startedAt"] = .string(startedAt.formatted(.iso8601))
        }
        return .object(["stream": .object(stream), "recording": .object(recording)])
    }

    /// The `tingra://program` document.
    static func programValue(of model: EngineModel) -> JSONValue {
        let shots = model.shots
        /// A shot as `{id, name}`, or null for no shot.
        func reference(_ id: ShotID?) -> JSONValue {
            guard let id, let shot = shots.first(where: { $0.id == id }) else { return .null }
            return .object(["id": .string(shot.id.rawValue), "name": .string(shot.name)])
        }
        let activePreset = model.activePresetID.flatMap { id in model.presets.first { $0.id == id } }
        return .object([
            "presets": .array(
                model.presets.map { .object(["id": .string($0.id.rawValue), "name": .string($0.name)]) }),
            "activePreset": activePreset.map { .object(["id": .string($0.id.rawValue), "name": .string($0.name)]) }
                ?? .null,
            "shots": .array(
                shots.map { shot in
                    .object([
                        "id": .string(shot.id.rawValue),
                        "name": .string(shot.name),
                        "origin": .string(shot.origin.rawValue),
                        "inputs": .array(shot.layers.map { .string($0.input.rawValue) }),
                    ])
                }),
            "programShot": reference(model.activeShotID),
            "previewShot": reference(model.previewShotID),
            "programInputs": .array(model.programInputIDs.map(\.rawValue).sorted().map(JSONValue.string)),
            "previewInputs": .array(model.previewInputIDs.map(\.rawValue).sorted().map(JSONValue.string)),
            "fadedToBlack": .bool(model.isFadedToBlack),
        ])
    }

    /// The `tingra://inputs` document.
    static func inputsValue(of model: EngineModel) -> JSONValue {
        /// One input's facts, merged from the model's lists.
        struct Entry {
            /// The user-facing name.
            var name: String
            /// The provenance.
            var kind: InputKind
            /// The media it produces, as the document names them.
            var media: Set<String>
        }
        var entries: [InputID: Entry] = [:]
        for choice in model.cameras + model.displays + model.videoInputs {
            entries[choice.id, default: Entry(name: choice.name, kind: choice.kind, media: [])].media.insert("video")
        }
        for choice in model.audioInputs {
            entries[choice.id, default: Entry(name: choice.name, kind: choice.kind, media: [])].media.insert("audio")
        }
        let paths = Dictionary(model.media.map { ($0.id.inputID, $0.path) }, uniquingKeysWith: { first, _ in first })
        let inputs = entries.sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }
            .map { id, entry -> JSONValue in
                var input: [String: JSONValue] = [
                    "id": .string(id.rawValue),
                    "name": .string(entry.name),
                    "kind": .string(entry.kind.rawValue),
                    "media": .array(entry.media.sorted().map(JSONValue.string)),
                ]
                if let path = paths[id] { input["path"] = .string(path) }
                return .object(input)
            }
        return .object(["inputs": .array(inputs)])
    }
}
