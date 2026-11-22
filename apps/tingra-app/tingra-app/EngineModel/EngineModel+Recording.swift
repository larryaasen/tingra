//
//  EngineModel+Recording.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraEventBus
import TingraHost
import TingraPlugInKit
import TingraRecordingPlugIns

/// Recording: starting and stopping a recording, its settings, and its status.
extension EngineModel {
    /// Starts recording the program to a local file: resolves the recording
    /// provider by the chosen container's extension and drives a **second**
    /// `StreamSession` carrying no destinations, fed by the same program tee
    /// the stream is (ARCHITECTURE.md, "Recording in the app").
    ///
    /// Independent of streaming by construction: recording can start before,
    /// during, or after a stream, and stopping one never stops the other. A
    /// second call while already recording is ignored.
    ///
    /// The file is named for the moment it starts and never overwrites an
    /// earlier take (see ``RecordingFilename``). A folder that cannot be
    /// created, or a volume without room for a usable take, surfaces as a
    /// recoverable error rather than a crash — the free-space refusal comes
    /// from the recording service itself, so the CLI enforces the same rule.
    func startRecording() async {
        guard recordSession == nil else { return }

        guard let provider = await outputs.recordingProvider(forFileExtension: recordingContainer.rawValue) else {
            recordingStatus = .error(
                String(
                    localized: "No recording output writes .\(recordingContainer.rawValue) files.",
                    comment: "Recording error when the chosen container has no registered recording output"
                )
            )
            return
        }

        // Create the folder if the operator has picked one that is not there
        // yet; a folder that cannot be created is reported rather than
        // silently falling back to somewhere they did not choose.
        do {
            try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
        } catch {
            reportRecordingError(
                String(
                    localized: "The recordings folder could not be created: \(error.localizedDescription)",
                    comment: "Recording error when the chosen folder cannot be created"
                )
            )
            return
        }

        let url = RecordingFilename.url(in: recordingFolder, container: recordingContainer, at: .now)
        let configuration = recordingConfiguration

        let (programStream, continuation) = AsyncStream.makeStream(
            of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        let (programAudioStream, audioContinuation) = AsyncStream.makeStream(
            of: CapturedAudio.self, bufferingPolicy: .bufferingNewest(AudioMixer.bufferedBlockCount))
        tee.attachRecording(video: continuation, audio: audioContinuation)

        let session = StreamSession(
            programVideo: programStream,
            programAudio: programAudioStream,
            destinations: [],
            configuration: configuration,
            policy: StreamSession.Policy(),
            clock: clock,
            eventBus: eventBus,
            recording: provider.makeRecordingService(configuration: configuration),
            recordingFile: RecordingFile(url: url, container: recordingContainer),
            // Both sessions emit `stream.started`/`stream.stopped` for their
            // own life; the label is what keeps the streaming panel from
            // reading the recording's.
            label: Self.recordSessionLabel
        )
        recordSession = session
        recordingStatus = .starting
        recordingURL = url

        recordTask = Task { [weak self] in
            do {
                _ = try await session.run()
                // A clean end settles through the `recording.stopped`
                // observer, like the stream's.
            } catch {
                // A setup failure — an unwritable folder, or a volume without
                // room — throws before any media is written.
                self?.reportRecordingError(String(describing: error))
            }
            self?.teardownRecording()
        }
    }

    /// Stops the recording: finalizes the file so it is playable. The
    /// `recording.stopped` event settles the status. A no-op when not
    /// recording.
    func stopRecording() async {
        guard recordSession != nil else { return }
        recordingStatus = .finalizing
        await recordSession?.stop()
    }

    /// Stops a recording in flight and waits for the file to be finalized.
    ///
    /// The waiting is the point, and it is why quitting is not simply
    /// ``stopRecording()``: `stop()` only *requests* the end, where the file
    /// becomes playable when the session's teardown finishes writing the
    /// index. A no-op when not recording.
    func finishRecording() async {
        guard let task = recordTask else { return }
        await stopRecording()
        await task.value
    }

    /// Reports a recording error on the bus and shows it on the control.
    ///
    /// - Parameter message: The developer-facing description (never a secret;
    ///   a recording path is not one).
    private func reportRecordingError(_ message: String) {
        eventBus.error(
            "recording.start",
            domain: .output,
            params: [
                "identifier": .string(ErrorIdentifier.recordingFailed.rawValue),
                "message": .string(message),
            ]
        )
        recordingStatus = .error(message)
    }

    /// Releases the finished recording session's plumbing so a new recording
    /// can start.
    private func teardownRecording() {
        tee.detachRecording()
        recordSession = nil
        recordTask = nil
        recordingStartedAt = nil
        // `recording.stopped` clears this too; clearing it here as well
        // means a session that ended without emitting it cannot leave the
        // Library believing a take is still being written.
        fileBeingRecorded = nil
        refreshRecordingCapacity()
    }

    /// Points recordings at a different folder, persisting the choice as a
    /// machine-local preference. Ignored while recording, so a take's file
    /// cannot move out from under it.
    ///
    /// - Parameter folder: The folder to record into.
    func setRecordingFolder(_ folder: URL) {
        guard !isRecording else { return }
        recordingFolder = folder
        recordingPreferences.folder = folder
        refreshRecordingCapacity()
        recordingRevision += 1
        eventBus.event("recording.folderChanged", domain: .output)
    }

    /// Changes the container recordings are muxed into, persisting the choice.
    /// Ignored while recording.
    ///
    /// - Parameter container: The container format.
    func setRecordingContainer(_ container: RecordingFile.Container) {
        guard !isRecording else { return }
        recordingContainer = container
        recordingPreferences.container = container
        refreshRecordingCapacity()
    }

    /// Changes the video codec recordings are compressed with, persisting
    /// the choice. Ignored while recording: a file is one codec from its
    /// first frame to its last. The room left is re-read, since the codec
    /// changes the video bit rate the estimate is computed from.
    ///
    /// - Parameter codec: The video codec.
    func setRecordingVideoCodec(_ codec: StreamConfiguration.VideoCodec) {
        guard !isRecording else { return }
        recordingVideoCodec = codec
        recordingPreferences.videoCodec = codec
        refreshRecordingCapacity()
    }

    /// Changes the audio bit rate recordings are compressed at, persisting
    /// the choice. Ignored while recording. A rate off the menu becomes the
    /// nearest one on it.
    ///
    /// - Parameter bitsPerSecond: The audio bit rate in bits per second.
    func setRecordingAudioBitsPerSecond(_ bitsPerSecond: Int) {
        guard !isRecording else { return }
        let rate = CompressionChoices.audioBitsPerSecond(nearest: bitsPerSecond)
        recordingAudioBitsPerSecond = rate
        recordingPreferences.audioBitsPerSecond = rate
        refreshRecordingCapacity()
    }

    /// Re-reads how much recording the chosen folder's volume holds.
    ///
    /// Called when the folder or container changes and when a recording ends
    /// — the moments the answer can have changed — never on a timer
    /// (no polling).
    func refreshRecordingCapacity() {
        recordingCapacity = RecordingCapacity.measure(at: recordingFolder)
    }

    /// Settles the Record control from the recording session's own
    /// session-level events — the events the streaming panel must not read.
    ///
    /// `stream.stopped` from this session is the recording's own end, and
    /// its reason distinguishes a clean stop from the sink dying with nothing
    /// left to feed (`recordingFailed`, the record-only outcome). The
    /// `recording.*` events that carry the file's own news are handled in
    /// ``handleRecordingEvent(_:)``.
    ///
    /// - Parameter event: An event drained from the bus carrying the record
    ///   session's label.
    func handleRecordingSessionEvent(_ event: EventBusEvent) {
        guard event.name == "stream.stopped" else { return }
        let reason = event.params?["reason"].flatMap(Self.stringValue)
        if reason == StreamSession.Outcome.recordingFailed.rawValue {
            // The write failure itself was already reported with its own
            // message by `recording.write`; leave that message standing.
            if case .error = recordingStatus {
            } else {
                recordingStatus = .error(
                    String(
                        localized: "The recording stopped and could not continue.",
                        comment: "Recording error shown when the file sink failed and the recording ended"
                    )
                )
            }
        } else if case .error = recordingStatus {
            // A start-time failure already settled the status.
        } else {
            recordingStatus = .idle
        }
    }

    /// Updates the Record control from the `recording.*` events the session
    /// emits for the file itself — event-driven, never polled, and the same
    /// events the CLI's `--json` output carries — and has the Library's
    /// Recordings tab re-read when a take appears and when it is finalized.
    ///
    /// Internal rather than private so tests drive it with a synthetic event
    /// instead of booting the engine.
    ///
    /// - Parameter event: An event drained from the bus.
    func handleRecordingEvent(_ event: EventBusEvent) {
        switch event.name {
        case "recording.started":
            recordingStatus = .recording
            recordingStartedAt = .now
            if let path = event.params?["path"].flatMap(Self.stringValue) {
                recordingURL = URL(filePath: path)
            }
            fileBeingRecorded = recordingURL
            recordingRevision += 1
        case "recording.stopped":
            // A recording that failed keeps its error showing; the file was
            // still finalized, which is what this event reports.
            if case .error = recordingStatus {} else { recordingStatus = .idle }
            recordingStartedAt = nil
            // Emitted after the file is closed, so this is the moment the
            // take becomes playable and its row an ordinary one.
            fileBeingRecorded = nil
            recordingRevision += 1
        case "recording.write":
            let message =
                event.params?["message"].flatMap(Self.stringValue)
                ?? String(
                    localized: "The recording stopped and could not continue.",
                    comment: "Recording error shown when the file sink failed and the recording ended"
                )
            recordingStatus = .error(message)
            recordingStartedAt = nil
        default:
            break
        }
    }
}
