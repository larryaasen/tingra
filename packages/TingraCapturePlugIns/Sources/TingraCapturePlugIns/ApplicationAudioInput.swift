//
//  ApplicationAudioInput.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Synchronization
import TingraApplicationAudio
import TingraEventBus
import TingraPlugInKit

/// One running application's sound behind the `Input` seam: a Core Audio
/// process tap over the application's own processes, read through
/// `TingraApplicationAudio` and delivered as `CMSampleBuffer`s stamped with
/// the IOProc's host time (ARCHITECTURE.md, "Application audio"; CLOCK.md,
/// Timestamp rules).
///
/// What shapes it (A4–A6):
///
/// - **It keeps the application off the speakers.** Its one parameter,
///   **Mute Application While Captured** (`mutesApplication`, on by
///   default), makes the tap silence the application on its own output
///   device while the input runs; stopping the input releases the tap and
///   the application is heard again. Changing the setting while running
///   rebuilds the tap.
/// - **The application may not be running.** That is not an error: the
///   input starts, reports `input.interrupted` with the reason
///   `applicationUnavailable`, and starts capturing when the application's
///   processes appear — learned from Core Audio's process-list listener, an
///   event, never a poll — reporting `input.resumed`. An application that
///   quits is `input.interrupted` the same way.
/// - **Its processes change.** A browser starts a helper process when
///   playback begins; any change to the application's set of processes
///   rebuilds the tap over the new set.
///
/// The first audio a start delivers is reported as `input.format`, carrying
/// `kind: application` — the proof a front end has that macOS allowed the
/// capture, since no API answers that question beforehand (A10).
///
/// Concurrency: as in ``WindowInput``, the capture lives inside one session
/// task that `start()` spawns and `stop()` ends, and every Core Audio call
/// is injected, so the rules here are unit-tested without a tap.
final class ApplicationAudioInput: Input, Sendable {
    /// The input's stable identifier — the project's, since an application
    /// is chosen rather than discovered.
    let id: InputID

    /// The application this input captures.
    private let application: CaptureApplication

    /// The host's event bus, for interruption, resumption, and the first
    /// audio, or nil where nothing listens.
    private let eventBus: EventBus?

    /// Finds the application's audio processes now: empty when it has none.
    private let findProcesses: @Sendable (String) throws -> [AudioObjectID]

    /// Subscribes to changes in the system's audio process list.
    private let processChanges: @Sendable () -> AsyncStream<Void>

    /// Starts one tap. Production taps through `TingraApplicationAudio`;
    /// tests inject a fake.
    private let startCapture: ApplicationCaptureStarter

    /// The parameter key of **Mute Application While Captured**.
    static let mutesApplicationKey = "mutesApplication"

    /// The one parameter the input declares.
    static let mutesApplicationParameter = Parameter(
        key: mutesApplicationKey, name: "Mute Application While Captured", defaultIsOn: true)

    /// The running session's signal stream, the single active audio
    /// continuation, and the muting setting — `Sendable` handles only.
    private let state = Mutex<CaptureState>(CaptureState())

    /// The mutable state behind the mutex.
    private struct CaptureState {
        /// Finishing this ends the session task, while started.
        var signal: AsyncStream<SessionSignal>.Continuation?

        /// The single active audio continuation, while a consumer is
        /// attached.
        var continuation: AsyncStream<CapturedAudio>.Continuation?

        /// Whether the tap mutes the application.
        var mutesApplication = true
    }

    /// What the session task reacts to, in the order it arrives.
    private enum SessionSignal: Sendable {
        /// The system's audio process list changed.
        case processesChanged

        /// The muting setting changed.
        case mutingChanged(Bool)

        /// The first audio of this start arrived.
        case audioArrived
    }

    /// Creates an application input.
    ///
    /// - Parameters:
    ///   - application: The application to capture.
    ///   - id: The identifier the input reports — the project's identity
    ///     for the application.
    ///   - eventBus: The host's event bus. Omit it where nothing listens.
    ///   - findProcesses: The process seam; defaults to Core Audio's list.
    ///   - processChanges: The process-list change seam.
    ///   - startCapture: The capture seam; defaults to a process tap.
    init(
        application: CaptureApplication,
        id: InputID,
        eventBus: EventBus? = nil,
        findProcesses: @escaping @Sendable (String) throws -> [AudioObjectID] = ApplicationAudioInput.liveProcesses,
        processChanges: @escaping @Sendable () -> AsyncStream<Void> = AudioProcessChanges.live,
        startCapture: @escaping ApplicationCaptureStarter = ApplicationAudioInput.startTap
    ) {
        self.application = application
        self.id = id
        self.eventBus = eventBus
        self.findProcesses = findProcesses
        self.processChanges = processChanges
        self.startCapture = startCapture
    }

    /// The application's name.
    var name: String { application.name }

    /// An application.
    var kind: InputKind { .application }

    /// An application input produces audio only.
    var media: InputMedia { .audio }

    /// **Mute Application While Captured**.
    var parameters: [Parameter] { [Self.mutesApplicationParameter] }

    /// Takes the muting setting, rebuilding a running tap when it changed.
    ///
    /// - Parameter parameters: The stored payload.
    func setParameters(_ parameters: [String: JSONValue]) async {
        let mutes = Self.mutesApplicationParameter.isOn(in: parameters) ?? true
        let signal = state.withLock { state -> AsyncStream<SessionSignal>.Continuation? in
            guard state.mutesApplication != mutes else { return nil }
            state.mutesApplication = mutes
            return state.signal
        }
        signal?.yield(.mutingChanged(mutes))
    }

    /// The muting setting as the input holds it.
    ///
    /// - Returns: The payload.
    func currentParameters() async -> [String: JSONValue] {
        [Self.mutesApplicationKey: .bool(state.withLock { $0.mutesApplication })]
    }

    /// Taps the application if it has audio processes, and runs the session
    /// that keeps the tap current.
    ///
    /// Throws ``CaptureInputError/configurationRejected(_:_:)`` when Core
    /// Audio will not list its processes or refuses the tap. **An
    /// application that is not running does not throw**: the input starts,
    /// reports `input.interrupted` (`applicationUnavailable`), and begins
    /// capturing when it appears.
    func start() async throws {
        let (signals, signal) = AsyncStream.makeStream(of: SessionSignal.self)
        let bundleIdentifier = application.bundleIdentifier
        let inputID = id
        let name = self.name
        let findProcesses = self.findProcesses
        let processChanges = self.processChanges
        let startCapture = self.startCapture
        let eventBus = self.eventBus
        let initialMutes = state.withLock { $0.mutesApplication }
        let report = DisplayInput.SessionReporter(eventBus: eventBus, id: inputID, name: name)
        let arrived = Mutex(false)
        let deliver: @Sendable (CapturedAudio) -> Void = { [weak self] audio in
            self?.state.withLock { $0.continuation }?.yield(audio)
            let first = arrived.withLock { arrived in
                defer { arrived = true }
                return !arrived
            }
            if first { signal.yield(.audioArrived) }
        }
        let capture: @Sendable ([AudioObjectID], Bool) throws -> any ApplicationCapture = { processes, mutes in
            try startCapture(processes, mutes, name, inputID, deliver)
        }
        let find: @Sendable () throws -> [AudioObjectID] = {
            do {
                return try findProcesses(bundleIdentifier)
            } catch {
                throw CaptureInputError.configurationRejected(inputID, String(describing: error))
            }
        }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            Task {
                var mutes = initialMutes
                var processes: [AudioObjectID]
                var running: (any ApplicationCapture)?
                do {
                    processes = try find()
                    if processes.isEmpty {
                        report.interrupted(reason: "applicationUnavailable", error: nil)
                    } else {
                        running = try capture(processes, mutes)
                    }
                } catch {
                    ready.resume(throwing: error)
                    return
                }
                ready.resume()
                let changes = Task {
                    for await _ in processChanges() {
                        signal.yield(.processesChanged)
                    }
                }
                // Until stop() finishes the signal stream. Holding `running`
                // here is what keeps the tap alive.
                for await next in signals {
                    switch next {
                    case .processesChanged:
                        // A list that cannot be read now leaves the capture
                        // as it is; the next change reads it again.
                        guard let now = try? find(), Set(now) != Set(processes) else { continue }
                        processes = now
                        let wasRunning = running != nil
                        running?.stop()
                        running = nil
                        if now.isEmpty {
                            if wasRunning { report.interrupted(reason: "applicationUnavailable", error: nil) }
                            continue
                        }
                        running = Self.restart(now, mutes, capture: capture, report: report, resumed: !wasRunning)
                    case .mutingChanged(let newMutes):
                        guard newMutes != mutes else { continue }
                        mutes = newMutes
                        guard let current = running else { continue }
                        current.stop()
                        running = Self.restart(processes, mutes, capture: capture, report: report, resumed: false)
                    case .audioArrived:
                        var params: [String: EventValue] = [
                            "id": .string(inputID.rawValue),
                            "name": .string(name),
                            "kind": .string(InputKind.application.rawValue),
                        ]
                        if let running {
                            params["sampleRate"] = .double(running.sampleRate)
                            params["channels"] = .int(running.channelCount)
                        }
                        eventBus?.event("input.format", domain: .capture, params: params)
                    }
                }
                changes.cancel()
                running?.stop()
            }
        }
        state.withLock { $0.signal = signal }
    }

    /// Starts a fresh tap, reporting `input.resumed` when asked to and an
    /// `input.resume` error when the tap cannot start.
    ///
    /// - Parameters:
    ///   - processes: The processes to tap.
    ///   - mutes: Whether the tap mutes them.
    ///   - capture: Starts the tap.
    ///   - report: Reports the outcome.
    ///   - resumed: Whether a start ends an interruption, so is reported.
    /// - Returns: The running tap, or nil when none started.
    private static func restart(
        _ processes: [AudioObjectID],
        _ mutes: Bool,
        capture: @Sendable ([AudioObjectID], Bool) throws -> any ApplicationCapture,
        report: DisplayInput.SessionReporter,
        resumed: Bool
    ) -> (any ApplicationCapture)? {
        do {
            let running = try capture(processes, mutes)
            if resumed { report.resumed() }
            return running
        } catch {
            report.resumeFailed(error)
            return nil
        }
    }

    /// The stream of captured audio. One consumer at a time: a new call
    /// finishes the previous stream and takes over. It stays open while the
    /// application is not running.
    func audio() -> AsyncStream<CapturedAudio> {
        AsyncStream { continuation in
            let previous = state.withLock { state in
                let previous = state.continuation
                state.continuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    /// Ends the session task (which releases the tap, so the application is
    /// heard again) and finishes the audio stream. Safe to call more than
    /// once.
    func stop() async {
        let (signal, continuation) = state.withLock { state in
            let pair = (state.signal, state.continuation)
            state.signal = nil
            state.continuation = nil
            return pair
        }
        signal?.finish()
        continuation?.finish()
    }

    // MARK: Core Audio

    /// The production process seam: the application's audio processes in
    /// Core Audio's list now, by the bundle-membership rule.
    static let liveProcesses: @Sendable (String) throws -> [AudioObjectID] = { bundleIdentifier in
        try AudioApplication.running(bundleIdentifier: bundleIdentifier)?.processes.map(\.objectID) ?? []
    }

    /// The production capture seam: a process tap whose copies become
    /// pipeline audio.
    static let startTap: ApplicationCaptureStarter = { processes, mutes, name, id, deliver in
        do {
            let tap = try ProcessTap.start(processes: processes, mutesProcesses: mutes, name: "Tingra: \(name)") {
                buffer in
                guard let audio = capturedAudio(from: buffer) else { return }
                deliver(audio)
            }
            return RunningTap(tap: tap)
        } catch {
            throw CaptureInputError.configurationRejected(id, String(describing: error))
        }
    }

    /// A running process tap, as the session holds it.
    private struct RunningTap: ApplicationCapture {
        /// The tap.
        let tap: ProcessTap

        /// The tap's sample rate.
        var sampleRate: Double { tap.sampleRate }

        /// The tap's channel count.
        var channelCount: Int { tap.channelCount }

        /// Releases the tap.
        func stop() {
            tap.stop()
        }
    }

    /// Wraps one tap callback's copy as pipeline audio: the samples in the
    /// canonical deinterleaved float form a microphone delivers, PTS the
    /// callback's host time on the master clock. Returns nil for a buffer
    /// with no frames, or one Core Media rejects — that buffer is skipped,
    /// never restamped with a synthetic position.
    ///
    /// - Parameter buffer: The tap's copy.
    /// - Returns: The audio, or nil.
    static func capturedAudio(from buffer: ApplicationAudioBuffer) -> CapturedAudio? {
        let frames = buffer.frameCount
        guard
            frames > 0,
            let format = MicrophoneInput.tapFormat(
                sampleRate: buffer.sampleRate, channels: AVAudioChannelCount(buffer.channelCount)),
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let channels = pcm.floatChannelData
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        buffer.samples.withUnsafeBufferPointer { samples in
            for channel in 0..<buffer.channelCount {
                let destination = channels[channel]
                for frame in 0..<frames {
                    destination[frame] = samples[frame * buffer.channelCount + channel]
                }
            }
        }
        return MicrophoneInput.capturedAudio(from: pcm, at: AVAudioTime(hostTime: buffer.hostTime))
    }
}

/// One running tap of an application, as the input's session holds it — a
/// process tap in production, a fake in tests. Not `Sendable`: it never
/// leaves the session task.
protocol ApplicationCapture {
    /// The capture's sample rate in hertz.
    var sampleRate: Double { get }

    /// The capture's channel count.
    var channelCount: Int { get }

    /// Releases the tap.
    func stop()
}

/// Starts one tap: given the processes, whether to mute them, the input's
/// name and identifier, and where audio goes, returns the running capture —
/// or throws why it could not start.
typealias ApplicationCaptureStarter =
    @Sendable (
        _ processes: [AudioObjectID],
        _ mutes: Bool,
        _ name: String,
        _ id: InputID,
        _ deliver: @escaping @Sendable (CapturedAudio) -> Void
    ) throws -> any ApplicationCapture
