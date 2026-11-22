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
    /// after the app dies").
    ///
    /// The marker is removed before anything else happens, so a second crash
    /// before the answer cannot ask twice about the same stream. A marker
    /// naming another project, or destinations that are no longer enabled
    /// and streamable, asks nothing and is reported as
    /// `stream.resumeSkipped`. The click goes on the bus before its effect,
    /// then `stream.resumeOffered` with the number of destinations named —
    /// counts only, never a URL or a key. Resuming is an ordinary
    /// ``startStreaming(only:)`` narrowed to the destinations the question
    /// named, so one added or enabled since stays off air.
    ///
    /// - Parameter ask: Asks the operator, naming the destinations and when
    ///   the stream went live (the alert by default; a scripted answer in
    ///   tests).
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
    /// streaming provider, reads each key from secure storage, and drives one
    /// ``StreamSession`` fanning the compositor's program frames and the
    /// mixer's program audio out to all of them — reusing the CLI's proven
    /// reconnect/stability/stats machinery (ARCHITECTURE.md, "Streaming the
    /// program", "Multiple destinations"). One active session (the v1 rule,
    /// now one session with N legs): a second call while streaming is ignored.
    ///
    /// The start is **best effort**: a destination that refuses the
    /// connection is reported and skipped while the others go live; only a
    /// clean sweep of refusals fails the run.
    ///
    /// Each stream key is read from secure storage, where the Streaming
    /// settings pane filed it as it was typed (``setStreamKey(_:for:)``), and
    /// used only to build its ``Destination``; none ever becomes an event
    /// param, a log line, or part of the project document. A destination with
    /// no stored key streams keyless (some servers embed the key in the URL
    /// path). Until 2026-09-08 the keys arrived as a value collected from the
    /// main window's rows at the click; the rows now live in the settings
    /// window, and a click in one window cannot read fields in another.
    ///
    /// - Parameter only: The destinations to stream to, or `nil` for every
    ///   streamable one. A resume names the ones its offer did
    ///   (``offerStreamResume(ask:)``), so a destination added or enabled
    ///   since cannot go on air unannounced.
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

        // The stream always carries the program mix — an all-muted mixer
        // streams silence, the way an empty shot streams the background
        // canvas (ARCHITECTURE.md, "The audio mixer"). Every leg encodes with
        // these settings; per-destination compression is a later iteration.
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

        // Tee the program into a fresh stream: the drains in `start()` forward
        // each composited frame and each mixed block here while the
        // continuations are set.
        // Bounded like the bus streams they mirror: the newest frame, and
        // the newest second of audio — a session that falls behind drops,
        // never queues (ARCHITECTURE.md, "Bounded frame streams").
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

    /// Takes the program off air: requests a clean stop of the active session
    /// (flush compression, close the connection). The `stream.stopped` event
    /// settles the status; ``teardownStream()`` releases the plumbing when
    /// `run()` returns. A no-op when not streaming, or when a stop is
    /// already under way.
    ///
    /// The status moves to ``StreamStatus/stopping`` **before** the request,
    /// because the session takes a few seconds to close and says nothing
    /// until it has: without it, a click on Stop Streaming looked ignored.
    /// The headline counters go with it — they describe delivery, and
    /// delivery is ending.
    func stopStreaming() async {
        guard let streamSession, streamStatus != .stopping else { return }
        streamStatus = .stopping
        streamStats = nil
        streamHealth.reset()
        await streamSession.stop()
    }

    /// Changes the audio bit rate the stream is compressed at, persisting
    /// the choice. Ignored while a stream session exists: the compressor is
    /// configured once, at Start. A rate off the menu becomes the nearest
    /// one on it.
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
        // `stream.stopped` clears these too; clearing them here as well
        // covers a session that ended without emitting it — a start that
        // threw after a destination had already reported its state.
        destinationStates = [:]
    }

    /// Shows one reading of the session's live statistics in the panel.
    ///
    /// The readings only fill in numbers; whether a destination is on air is
    /// the bus's to say (``handleStreamStatusEvent(_:)``). So a reading that
    /// crossed a reconnect or the stream's end on its way here never brings a
    /// row back to Live.
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
    /// each live destination's own, and the headline — the first live
    /// destination's, never an average across destinations that describes
    /// none of them.
    ///
    /// A reading for a destination that is not live by its own events is
    /// dropped, so the readout can never contradict the destination's state.
    ///
    /// - Parameters:
    ///   - readings: One reading of every delivering leg.
    ///   - destinationStates: Each destination's state from its bus events.
    ///   - destinationOrder: The destinations in the panel's order, which
    ///     decides the first live one.
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
    /// `stream.*` bus event — the event-driven status the CLI's
    /// `StreamSession` already emits (`stream.started`, the per-leg
    /// `stream.destination.*`, `stream.reconnecting`, `stream.reconnected`,
    /// `stream.stopped`); no polling. Non-stream events are ignored.
    ///
    /// The session-level status answers "are we on air"; a leg's own events
    /// answer "is *this* destination on air", so one destination reconnecting
    /// colors its row without claiming the whole stream is in trouble
    /// (ARCHITECTURE.md, "Multiple destinations").
    ///
    /// The stream session's `stream.started` and `stream.stopped` also keep
    /// the ``LiveStreamRecord``: written when the stream goes live, removed
    /// when it stops, whatever the reason. The recording session's events
    /// never touch it. Not private, so a test can hand it a stop.
    ///
    /// - Parameter event: An event drained from the bus.
    func handleStreamStatusEvent(_ event: EventBusEvent) {
        // The recording runs its own session, which reports its own life with
        // the same two session-level event names. Its events belong to the
        // Record control, never to the streaming panel.
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
            // On air from here: a run that ends before `stream.stopped` is
            // one the next launch offers to resume. IDs only, never a URL
            // or a key. The legs are the streamable destinations, which
            // cannot be edited while live, less any that rejected the
            // connection: the session reports those before it reports
            // itself started, and they were never on air.
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
        // `stream.stats` carries no figure the panel reads: the app's line is
        // the log's once-a-minute window summary, and the panel reads the
        // session's live statistics instead (``applyLiveStatistics(_:)``).
        // It is what says the stream is still on air, though, so the history
        // stamps its open entry with it.
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
            // Whatever the reason: a stream that ended on its own was not
            // cut short by the app dying, and offering to restart it would
            // be wrong.
            liveStreamRecord.remove()
            recordStreamEnded(
                reason: reason == StreamSession.Outcome.connectionLost.rawValue ? .connectionLost : .stopped,
                at: event.date)
        default:
            break
        }
    }

    /// Enters the session that just went on air in the stream history: the
    /// destinations it went on air to — every streamed destination but those
    /// that refused the connection, whose `stream.destination.rejected`
    /// precedes `stream.started` — and the program format, both of which the
    /// session holds locked until it has closed.
    ///
    /// Nothing is recorded once ``removeAllData()`` has run, the rule
    /// autosave follows: a history the operator just removed is not written
    /// back by the stream that is still on air.
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

    /// Moves the stream status to a running state reported by the session —
    /// unless a stop is under way, which only the stream's end
    /// (`stream.stopped`, or a start-time failure) settles. A leg that
    /// finishes connecting, or recovers, while the session closes must not
    /// flip Stopping… back to Live.
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
