//
//  EngineModel+Snapshots.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreImage
import Foundation
import TingraComposition
import TingraEventBus
import TingraPlugInKit

/// Snapshots: saving a still image of a monitor.
extension EngineModel {
    /// Saves the frame a monitor is showing as a PNG in the snapshots folder
    /// (ARCHITECTURE.md, "Snapshots").
    ///
    /// Reads the monitor's own ``MonitorFrameSource`` with the two calls a
    /// draw makes — `latest`, then `image(for:)` — so what is saved is what
    /// the monitor shows by construction. The frame is read here, on the
    /// main actor as a draw reads it, and handed to the writer's off-main
    /// render, which lets go of it before the encode. A monitor showing
    /// nothing writes nothing: a `snapshot.unavailable` trace and a No
    /// Picture to Save badge. The outcome is a badge on the monitor, never
    /// a sound or a flash.
    ///
    /// - Parameter subject: The monitor to save.
    func saveSnapshot(_ subject: SnapshotSubject) async {
        // The moment of the request names the file, not the moment of the
        // write.
        let requestedAt = Date.now
        let subjectName = snapshotSubjectName(for: subject)
        var params = snapshotParams(for: subject)
        guard let image = snapshotImage(for: subject) else {
            eventBus.trace("snapshot.unavailable", domain: .composition, params: params)
            showSnapshotFeedback(SnapshotFeedback(subject: subject, outcome: .noPicture))
            return
        }
        do {
            let png = try await snapshotWriter.encode(consume image)
            let url = try await snapshotWriter.write(png, subject: subjectName, at: requestedAt, in: snapshotFolder)
            // The file's name only, never its folder — the media rule.
            params["file"] = .string(url.lastPathComponent)
            params["width"] = .int(png.width)
            params["height"] = .int(png.height)
            eventBus.event("snapshot.saved", domain: .composition, params: params)
            snapshotRevision += 1
            showSnapshotFeedback(SnapshotFeedback(subject: subject, outcome: .saved(fileName: url.lastPathComponent)))
        } catch {
            let snapshotError = error as? SnapshotError
            params["error"] = .string(snapshotError?.description ?? String(describing: error))
            eventBus.error("snapshot.save", domain: .composition, params: params)
            showSnapshotFeedback(
                SnapshotFeedback(
                    subject: subject,
                    outcome: .notSaved(message: snapshotError?.operatorMessage ?? error.localizedDescription)
                )
            )
        }
    }

    /// The frame source a subject's monitor draws — the same one, so a
    /// snapshot and a draw cannot disagree. The layer's is a **fresh**
    /// ``LayerMonitorSource``, whose effect instances are its own, so a
    /// snapshot never advances the on-screen monitor's chain state.
    ///
    /// - Parameter subject: The monitor.
    /// - Returns: Its frame source.
    func snapshotSource(for subject: SnapshotSubject) -> any MonitorFrameSource {
        switch subject {
        case .program: programRelay
        case .preview: previewRelay
        case .input(let id): InputFrameSource(model: self, id: id)
        case .layer: LayerMonitorSource(model: self)
        }
    }

    /// What a snapshot of a subject is called in its file name, in the
    /// operator's language: Program, Preview, the input's name (a media
    /// input's without its file extension), or "<input> Layer".
    ///
    /// - Parameter subject: The monitor.
    /// - Returns: The subject's name.
    func snapshotSubjectName(for subject: SnapshotSubject) -> String {
        switch subject {
        case .program:
            // The same key and comment as the monitor's badge, so the
            // catalog keeps one entry for the one word.
            String(localized: "Program", comment: "Name of the program bus — labels its monitor and its switcher row")
        case .preview:
            String(localized: "Preview", comment: "Name of the preview bus — labels its monitor and its switcher row")
        case .input(let id):
            snapshotInputName(for: id)
        case .layer:
            if let layer = selectedLayer?.layer {
                String(
                    localized: "\(snapshotInputName(for: layer.input)) Layer",
                    comment: "Snapshot file name subject for the layer monitor: the layer's input name, then “Layer”")
            } else {
                String(localized: "Layer", comment: "Title of the Layer menu, arranging the selected layer")
            }
        }
    }

    /// Points snapshots at a different folder, persisting the choice as a
    /// machine-local preference, and has the Library re-read.
    ///
    /// - Parameter folder: The folder to save into.
    func setSnapshotFolder(_ folder: URL) {
        snapshotFolder = folder
        snapshotPreferences.folder = folder
        snapshotRevision += 1
        eventBus.event("snapshot.folderChanged", domain: .composition)
    }

    /// The picture a subject's monitor would draw now, or nil when it shows
    /// nothing. The pixel buffer is held only inside this call; the image
    /// returned is the one reference that keeps it until the render.
    ///
    /// - Parameter subject: The monitor.
    /// - Returns: The picture, or nil.
    private func snapshotImage(for subject: SnapshotSubject) -> CIImage? {
        let source = snapshotSource(for: subject)
        guard let pixelBuffer = source.latest else { return nil }
        return source.image(for: pixelBuffer)
    }

    /// An input's name for a file name: a media input's without the file's
    /// extension, since "Poster.png" would read "Tingra Poster.png 2026-….png".
    ///
    /// - Parameter id: The input.
    /// - Returns: The name.
    private func snapshotInputName(for id: InputID) -> String {
        let name = inputName(for: id)
        guard let item = mediaItem(forInput: id) else { return name }
        let fileExtension = item.url.pathExtension
        guard !fileExtension.isEmpty, name.lowercased().hasSuffix("." + fileExtension.lowercased()) else {
            return name
        }
        return String(name.dropLast(fileExtension.count + 1))
    }

    /// The params every `snapshot.*` event for a subject carries: its kind,
    /// and the input's id where there is one.
    ///
    /// - Parameter subject: The monitor.
    /// - Returns: The params.
    private func snapshotParams(for subject: SnapshotSubject) -> [String: EventValue] {
        var params: [String: EventValue] = ["subject": .string(subject.kind)]
        if let input = subject.inputID ?? (subject == .layer ? selectedLayer?.layer.input : nil) {
            params["input"] = .string(input.rawValue)
        }
        return params
    }

    /// Puts a badge on the subject's monitor and takes it down after its
    /// time — unless a newer request has replaced it by then.
    ///
    /// - Parameter feedback: The badge.
    private func showSnapshotFeedback(_ feedback: SnapshotFeedback) {
        snapshotFeedback = feedback
        snapshotFeedbackTask?.cancel()
        snapshotFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: feedback.displayDuration)
            guard !Task.isCancelled, let self, self.snapshotFeedback?.id == feedback.id else { return }
            self.snapshotFeedback = nil
        }
    }
}
