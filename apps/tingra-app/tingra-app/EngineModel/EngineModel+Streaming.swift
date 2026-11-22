//
//  EngineModel+Streaming.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-11-22.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import TingraAudio
import TingraComposition
import TingraEventBus
import TingraHost
import TingraPlugInKit

/// Streaming: starting and stopping the stream, and following its status and statistics.
extension EngineModel {
    /// Offers to go live again when the last run ended while it was live,
    /// and acts on the answer (ARCHITECTURE.md, "Offering to resume a stream
    /// after the app dies"). The marker is removed first, so a second crash
    /// before the answer cannot ask twice. A marker naming another project,
    /// or destinations no longer enabled and streamable, asks nothing and is
    /// reported as `stream.resumeSkipped`. Resuming is
    /// ``startStreaming(only:)`` narrowed to the destinations it named.
    ///
    /// - Parameter ask: Asks the operator, naming the destinations and when
    ///   the stream went live (the alert by default, scripted in tests).
    func offerStreamResume(
        ask: @MainActor (_ destinations: [String], _ wentLive: Date) -> StreamResumeOffer.Answer = {
            StreamResumeAlert.ask(destinations: $0, wentLive: $1)
        }
    ) async {
        let record = liveStreamRecord.read()
        liveStreamRecord.remove()
        switch StreamResumeOffer.decide(record: record, projectURL: projectURL, destinations: destinations) {
        case .none:
            break
        case .skip(let reason):
            eventBus.event("stream.resumeSkipped", domain: .output, params: ["reason": .string(reason.rawValue)])
        case .ask(let offered, let wentLive):
            let answer = ask(offered.map(\.displayName), wentLive)
            eventBus.tap(answer.tapName, domain: .output)
            eventBus.event("stream.resumeOffered", domain: .output, params: ["destinations": .int(offered.count)])
            if answer == .resume {
                await startStreaming(only: Set(offered.map(\.id)))
            }
        }
    }

    /// Puts the program on air: resolves every enabled destination to its
    /// streaming provider and drives one ``StreamSession`` fanning the
    /// program out to all of them (ARCHITECTURE.md, "Streaming the program",
    /// "Multiple destinations"). Ignored while already streaming.
    ///
    /// The start is best effort: a destination that refuses the connection
    /// is reported and skipped, and only a clean sweep of refusals fails the
    /// run. Each stream key is read from secure storage
    /// (``setStreamKey(_:for:)``) and used only to build its
    /// ``Destination``, never an event param, a log line, or the project
    /// document. A destination with no stored key streams keyless.
    ///
    /// - Parameter only: The destinations to stream to, or `nil` for every
    ///   streamable one, as a resume names (``offerStreamResume(ask:)``).
    func startStreaming(only: Set<ProjectDestinationID>?) async {
        guard streamSession == nil else { return }
        let streamable = DestinationEdit.streamable(in: destinations, only: only)
        guard !streamable.isEmpty else {
            streamStatus = .error(
                String(
                    localized: "Add a destination with an rtmp://, rtmps://, or srt:// URL, then start again.",
                    comment: "Stream error shown when no destination is enabled and has a usable URL"
                )
            )
            return
        }

        // The stream always carries the program mix: an all-muted mixer
        // streams silence (ARCHITECTURE.md, "The audio mixer"). Every leg
        // shares these settings; per-destination compression comes later.
        let configuration = streamConfiguration

        var legs: [StreamSession.DestinationLeg] = []
        for destination in streamable {
            guard let url = destination.url, let scheme = url.scheme?.lowercased() else { continue }
            guard let provider = await outputs.provider(forScheme: scheme) else {
                streamStatus = .error(
                    String(
                        localized: "No streaming output serves \(scheme) destinations. Use rtmp, rtmps, or srt.",
                        comment: "Stream error when a destination's URL scheme has no registered output"
                    )
                )
                return
            }
            // The key comes from secure storage, filed under the destination
            // id; a read error is reported there and reads as no key.
            let key = storedStreamKey(for: destination.id) ?? ""
            legs.append(
                StreamSession.DestinationLeg(
                    id: destination.id.rawValue,
                    destination: Destination(url: url, streamKey: key.isEmpty ? nil : key),
                    service: provider.makeStreamingService(configuration: configuration)
                )
            )
        }

        // Tee the program into a fresh stream, bounded like the bus streams
        // it mirrors: a session that falls behind drops, never queues
        // (ARCHITECTURE.md, "Bounded frame streams").
        let (programStream, continuation) = AsyncStream.makeStream(
            of: CapturedFrame.self, bufferingPolicy: .bufferingNewest(1))
        let (programAudioStream, audioContinuation) = AsyncStream.makeStream(
            of: CapturedAudio.self, bufferingPolicy: .bufferingNewest(AudioMixer.bufferedBlockCount))
        tee.attachStream(video: continuation, audio: audioContinuation)

        let session = StreamSession(
            programVideo: programStream,
            programAudio: programAudioStream,
            destinations: legs,
            configuration: configuration,
            policy: StreamSession.Policy(
                statsIntervalSeconds: Self.streamStatsLogIntervalSeconds,
                liveStatistics: true
            ),
            clock: clock,
            eventBus: eventBus
        )
        streamSession = session
        streamStatus = .starting
        streamStats = nil
        streamHealth.reset()
        streamStartedAt = nil
        destinationStats = [:]
        destinationStates = [:]

        // The panel's figures come from the session's live statistics, not
        // from `stream.stats`: the bus line is the log's, once a minute.
        streamStatisticsTask = Task { [weak self] in
            for await readings in session.liveStatistics {
                self?.applyLiveStatistics(readings)
            }
        }

        streamTask = Task { [weak self] in
            do {
                _ = try await session.run()
                // Terminal status is set by the `stream.stopped` observer; the
                // task only tears the plumbing down.
            } catch {
                // A start-time failure (bad key, unreachable host) throws
                // before `stream.started`, so the observer never saw it.
                self?.eventBus.error(
                    "stream.start",
                    domain: .output,
                    params: [
                        "identifier": .string(ErrorIdentifier.connectionFailed.rawValue),
                        "message": .string(String(describing: error)),
                    ]
                )
                self?.streamStatus = .error(String(describing: error))
            }
            self?.teardownStream()
        }
    }

    /// Puts the program on air to every streamable destination: what the
    /// Start control and the `program_stream_start` tool ask for
    /// (``startStreaming(only:)`` with no narrowing).
    func startStreaming() async {
        await startStreaming(only: nil)
    }

    /// Takes the program off air with a clean stop of the active session.
    /// `stream.stopped` settles the status and ``teardownStream()`` releases
    /// the plumbing. A no-op when not streaming or already stopping.
    ///
    /// The status moves to ``StreamStatus/stopping`` before the request,
    /// because the session takes seconds to close and says nothing until it
    /// has. The headline counters clear with it, since delivery is ending.
    func stopStreaming() async {
        guard let streamSession, streamStatus != .stopping else { return }
        streamStatus = .stopping
        streamStats = nil
        streamHealth.reset()
        await streamSession.stop()
    }

    /// Changes the audio bit rate the stream is compressed at, persisting
    /// the choice. Ignored while a stream session exists, since compression
    /// is configured once at Start. A rate off the menu snaps to the nearest.
    ///
    /// - Parameter bitsPerSecond: The audio bit rate in bits per second.
    func setStreamAudioBitsPerSecond(_ bitsPerSecond: Int) {
        guard !isStreaming else { return }
        let rate = CompressionChoices.audioBitsPerSecond(nearest: bitsPerSecond)
        streamAudioBitsPerSecond = rate
        streamingPreferences.audioBitsPerSecond = rate
    }

    /// Releases the finished session's plumbing: finishes the program tees
    /// and drops the session references so a new stream can start.
    private func teardownStream() {
        tee.detachStream()
        streamStatisticsTask?.cancel()
        streamStatisticsTask = nil
        streamSession = nil
        streamTask = nil
        // `stream.stopped` clears these too; this covers a start that threw
        // after a destination had already reported its state.
        destinationStates = [:]
    }

    /// Shows one reading of the session's live statistics in the panel. The
    /// readings only fill in numbers; whether a destination is on air is the
    /// bus's to say (``handleStreamStatusEvent(_:)``), so a late reading
    /// never brings a row back to Live.
    ///
    /// - Parameter readings: One reading of every delivering leg.
    private func applyLiveStatistics(_ readings: [StreamSession.LegStatistics]) {
        guard streamSession != nil else { return }
        let panel = Self.panelStats(
            for: readings,
            destinationStates: destinationStates,
            destinationOrder: destinations.map(\.id)
        )
        destinationStats.merge(panel.perDestination) { _, new in new }
        // None while stopping, when delivery is ending.
        if let headline = panel.headline, !isStoppingStream {
            streamStats = headline
            streamHealth.record(headline, frameRate: format.frameRate)
        }
    }

    /// The panel's figures from one reading of the session's live statistics:
    /// each live destination's own, and the headline, which is the first live
    /// destination's, never an average. A reading for a destination not live
    /// by its own events is dropped, so the readout never contradicts it.
    ///
    /// - Parameters:
    ///   - readings: One reading of every delivering leg.
    ///   - destinationStates: Each destination's state from its bus events.
    ///   - destinationOrder: The destinations in the panel's order.
    /// - Returns: The figures for each live destination read, and the
    ///   headline when the first live destination was among them.
    static func panelStats(
        for readings: [StreamSession.LegStatistics],
        destinationStates: [ProjectDestinationID: DestinationState],
        destinationOrder: [ProjectDestinationID]
    ) -> (perDestination: [ProjectDestinationID: StreamStats], headline: StreamStats?) {
        var perDestination: [ProjectDestinationID: StreamStats] = [:]
        for reading in readings {
            let id = ProjectDestinationID(rawValue: reading.destination)
            guard destinationStates[id] == .live else { continue }
            // Bytes per second arrive from the service; the panel shows kbps.
            perDestination[id] = StreamStats(
                bitrateKbps: reading.statistics.bytesPerSecond * 8 / 1000,
                fps: reading.statistics.framesPerSecond
            )
        }
        let firstLive = destinationOrder.first { destinationStates[$0] == .live }
        return (perDestination, firstLive.flatMap { perDestination[$0] })
    }

    /// Updates ``streamStatus`` and the per-destination state from a
    /// `stream.*` bus event; other events are ignored. The session-level
    /// status says whether the stream is on air and a leg's own events say
    /// whether its destination is (ARCHITECTURE.md, "Multiple destinations").
    /// `stream.started` and `stream.stopped` also write and remove the
    /// ``LiveStreamRecord``. Not private, so a test can hand it a stop.
    ///
    /// - Parameter event: An event drained from the bus.
    func handleStreamStatusEvent(_ event: EventBusEvent) {
        // The recording session reports with the same session-level event
        // names; its events belong to the Record control, not this panel.
        if event.params?["session"].flatMap(Self.stringValue) == Self.recordSessionLabel {
            handleRecordingSessionEvent(event)
            return
        }
        handleRecordingEvent(event)
        let destination = event.params?["destination"].flatMap(Self.stringValue).map(ProjectDestinationID.init)
        switch event.name {
        case "stream.started":
            setActiveStreamStatus(.live)
            streamStartedAt = event.date
            // A run that ends before `stream.stopped` is one the next launch
            // offers to resume. IDs only, never a URL or a key, and none for a
            // destination that rejected the connection: it was never on air.
            liveStreamRecord.write(
                LiveStreamRecord.Contents(
                    project: projectURL,
                    destinations: StreamResumeOffer.liveDestinationIDs(
                        of: destinations, states: destinationStates),
                    wentLive: event.date))
            recordStreamStarted(at: event.date)
        case "stream.destination.started":
            setDestinationState(.live, for: destination)
        case "stream.destination.rejected":
            setDestinationState(.rejected, for: destination)
        case "stream.destination.lost":
            setDestinationState(.lost, for: destination)
            if let destination { destinationStats[destination] = nil }
        case "stream.reconnected":
            // The session as a whole is live again as soon as any leg is; a
            // leg still down keeps its own row's state.
            setActiveStreamStatus(.live)
            setDestinationState(.live, for: destination)
        // Not a figure the panel reads (``applyLiveStatistics(_:)``), but it
        // says the stream is still on air, so the history stamps its entry.
        case "stream.stats":
            if !isRemovingData { streamHistory.markOnAir(at: event.date) }
        case "stream.reconnecting":
            let attempt = event.params?["attempt"].flatMap(Self.intValue) ?? 0
            let maxAttempts = event.params?["maxAttempts"].flatMap(Self.intValue) ?? 0
            setDestinationState(.reconnecting(attempt: attempt, maxAttempts: maxAttempts), for: destination)
            if let destination { destinationStats[destination] = nil }
            // The session banner reports trouble only when nothing is left
            // delivering; one leg of several reconnecting is that leg's news.
            if !destinationStates.values.contains(.live), !isStoppingStream {
                setActiveStreamStatus(.reconnecting(attempt: attempt, maxAttempts: maxAttempts))
                streamStats = nil
                streamHealth.reset()
            }
        case "stream.stopped":
            // The session reports its outcome as the stop reason; every leg
            // being lost past its reconnect budget is the failure case.
            let reason = event.params?["reason"].flatMap(Self.stringValue)
            streamStatus =
                reason == StreamSession.Outcome.connectionLost.rawValue
                ? .error(
                    String(
                        localized: "Every destination was lost and not recovered.",
                        comment: "Stream error shown when the last live destination was lost"
                    )
                )
                : .stopped
            streamStats = nil
            streamHealth.reset()
            streamStartedAt = nil
            destinationStats = [:]
            // Off air, no destination has a state: a row left reading Live
            // after the stop is what clearing them here prevents.
            destinationStates = [:]
            // Whatever the reason: a stream that ended on its own was not cut
            // short by the app dying, so there is nothing to offer to resume.
            liveStreamRecord.remove()
            recordStreamEnded(
                reason: reason == StreamSession.Outcome.connectionLost.rawValue ? .connectionLost : .stopped,
                at: event.date)
        default:
            break
        }
    }

    /// Enters the session that just went on air in the stream history, with
    /// the program format and every streamed destination but those that
    /// refused the connection. Nothing is recorded once ``removeAllData()``
    /// has run, so a removed history is not written back by a live stream.
    ///
    /// - Parameter date: When the session reported going on air.
    private func recordStreamStarted(at date: Date) {
        guard !isRemovingData else { return }
        let onAir = destinations.filter { $0.isStreamable && destinationStates[$0.id] != .rejected }
        streamHistory.begin(
            destinations: onAir.map(\.displayName),
            width: format.width,
            height: format.height,
            frameRate: format.frameRate,
            at: date
        )
    }

    /// Closes the stream history's open entry, if there is one.
    ///
    /// - Parameters:
    ///   - reason: How the session ended.
    ///   - date: When it ended.
    func recordStreamEnded(reason: StreamHistoryEndReason, at date: Date) {
        guard !isRemovingData else { return }
        streamHistory.end(reason: reason, at: date)
    }

    /// Moves the stream status to a running state the session reported,
    /// unless a stop is under way: a leg that finishes connecting or recovers
    /// while the session closes must not flip Stopping… back to Live.
    ///
    /// - Parameter status: The running state the session reported.
    private func setActiveStreamStatus(_ status: StreamStatus) {
        guard !isStoppingStream else { return }
        streamStatus = status
    }

    /// Records one destination's live state, ignoring an event that names no
    /// destination (or one no longer in the panel).
    ///
    /// - Parameters:
    ///   - state: The state to record.
    ///   - id: The destination the event named, if any.
    private func setDestinationState(_ state: DestinationState, for id: ProjectDestinationID?) {
        guard let id else { return }
        destinationStates[id] = state
    }
}
