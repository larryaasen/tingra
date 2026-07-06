//
//  Compositor.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Synchronization
import TingraEventBus
import TingraPlugInKit

/// The tick-paced Metal/Core Image compositor: it renders the current shot's
/// layer tree to one program frame per program tick (CLOCK.md, "The program
/// tick"). This is the step-6 realization of the model the single-input
/// ``ProgramPacer`` stood in for during the CLI era — same tick, same
/// latest-wins slot semantics, same timestamps, with "take the latest frame"
/// replaced by "render the layer tree" across every input.
///
/// It holds a latest-wins slot per input (a fill task drains each input's
/// `frames()` stream into it) and the current ``Shot``. On each tick it
/// snapshots the shot and the slots, hands them to a task-confined
/// ``ShotRenderer``, and yields the composited program frame — stamped with
/// the tick's master clock time, so sinks receive a clean, monotonic,
/// constant-rate PTS regardless of any input's native cadence. A stalled
/// input keeps its last frame in its slot, so its layer keeps compositing
/// (a stalled input does not stall the program); the program is a live
/// canvas from the first tick, showing the background before any input
/// delivers.
///
/// Ownership (ARCHITECTURE.md, "Frame ownership across the `Input` seam"):
/// the compositor is the one holder of each input's latest frame, releasing
/// the previous frame as a newer one replaces it in the slot; the renderer
/// only reads the held, immutable frames and composites them into a fresh
/// program buffer.
///
/// The mutating controls (``setInputs(_:)``, ``setShot(_:)``, ``start()``,
/// ``stop()``) are meant to be driven from one context (the app's main
/// actor); they are internally locked but not designed for concurrent
/// callers racing each other.
public final class Compositor: Sendable {
    /// The clock whose tick paces the program (the master clock in
    /// production, a synthetic clock in tests).
    private let clock: any EngineClock

    /// The program geometry and rate every frame is rendered at.
    private let format: ProgramFormat

    /// The host's event bus, carrying the compositor's control-plane events
    /// (never per-frame traffic — EVENTS.md).
    private let eventBus: EventBus

    /// Builds the shot renderer. Called once, inside the tick task, so the
    /// renderer (and its `CIContext`) stays task-confined and needs no
    /// `Sendable` conformance (see ``ShotRenderer``).
    private let makeRenderer: @Sendable () -> any ShotRenderer

    /// The compositor's live state behind a mutex — the fill tasks, tick
    /// task, and program-frame consumers all touch it from different tasks.
    private let state = Mutex(State())

    /// The mutable compositor state.
    private struct State {
        /// The latest frame each input has produced, keyed by id — the
        /// latest-wins slots. A replaced frame is released as it is
        /// overwritten (the ownership rule's "one holder at a time").
        var slots: [InputID: CapturedFrame] = [:]

        /// The frame-draining task per input, so inputs can be swapped and
        /// cancelled cleanly.
        var fillTasks: [InputID: Task<Void, Never>] = [:]

        /// The current shot the tick renders.
        var shot = Shot()

        /// The single active program-frame consumer, while attached.
        var programContinuation: AsyncStream<CapturedFrame>.Continuation?

        /// The running tick task, while started.
        var tickTask: Task<Void, Never>?
    }

    /// Creates a compositor.
    ///
    /// - Parameters:
    ///   - clock: The clock whose tick paces the program.
    ///   - format: The program geometry and rate (default 1920x1080 at 30).
    ///   - eventBus: The host's event bus.
    ///   - makeRenderer: The shot-renderer factory; defaults to the
    ///     Metal-backed Core Image renderer. Tests inject a factory that
    ///     builds a mock renderer.
    public init(
        clock: any EngineClock,
        format: ProgramFormat = ProgramFormat(),
        eventBus: EventBus,
        makeRenderer: @escaping @Sendable () -> any ShotRenderer = { CoreImageShotRenderer() }
    ) {
        self.clock = clock
        self.format = format
        self.eventBus = eventBus
        self.makeRenderer = makeRenderer
    }

    /// The program-frame stream: one composited frame per program tick. A
    /// new call replaces the previous consumer (finishing its stream),
    /// matching the one-consumer contract the media seams use.
    public func programFrames() -> AsyncStream<CapturedFrame> {
        AsyncStream { continuation in
            let previous = state.withLock { state in
                let previous = state.programContinuation
                state.programContinuation = continuation
                return previous
            }
            previous?.finish()
        }
    }

    /// Sets the inputs whose frames feed the shot's layers. Inputs must
    /// already be started (the compositor composites; it does not own device
    /// lifecycle). Inputs no longer present have their fill task cancelled
    /// and their slot cleared; newly present inputs get a fill task draining
    /// their `frames()` into a slot.
    ///
    /// - Parameter inputs: The inputs available to the current (and future)
    ///   shots.
    public func setInputs(_ inputs: [any Input]) {
        let desiredIDs = Set(inputs.map(\.id))
        // Snapshot the frame streams for genuinely new inputs outside the
        // lock: `frames()` finishes any previous consumer (one holder at a
        // time), so it must be called once per new input, never for one
        // already being drained.
        let trackedIDs = state.withLock { Set($0.fillTasks.keys) }
        let newStreams = inputs.filter { !trackedIDs.contains($0.id) }.map { ($0.id, $0.frames()) }

        state.withLock { state in
            for (id, task) in state.fillTasks where !desiredIDs.contains(id) {
                task.cancel()
                state.fillTasks[id] = nil
                state.slots[id] = nil
            }
            for (id, stream) in newStreams {
                state.fillTasks[id] = Task { [weak self] in
                    for await frame in stream {
                        self?.store(frame, for: id)
                    }
                }
            }
        }
    }

    /// Switches the shot the tick renders. Takes effect on the next tick —
    /// switching shots does not interrupt pacing (GLOSSARY.md, "Shot").
    ///
    /// - Parameter shot: The new layer tree and background.
    public func setShot(_ shot: Shot) {
        state.withLock { $0.shot = shot }
    }

    /// Starts the program tick: the compositor renders and yields one frame
    /// per tick until ``stop()``. Idempotent — a second call while running
    /// does nothing.
    public func start() {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(format.frameRate))
        let clock = self.clock
        let format = self.format
        let makeRenderer = self.makeRenderer

        state.withLock { state in
            guard state.tickTask == nil else { return }
            state.tickTask = Task { [weak self] in
                // The renderer lives entirely inside this task; program
                // frames leave it only through the continuation's yield.
                let renderer = makeRenderer()
                for await tickTime in clock.tick(every: frameDuration) {
                    guard !Task.isCancelled, let self else { break }
                    let (shot, frames, continuation) = self.state.withLock {
                        ($0.shot, $0.slots, $0.programContinuation)
                    }
                    guard let continuation else { continue }
                    if let program = renderer.render(shot: shot, frames: frames, format: format, time: tickTime) {
                        continuation.yield(program)
                    }
                }
            }
        }
        eventBus.event(
            "program.started",
            domain: .composition,
            params: [
                "resolution": .string("\(format.width)x\(format.height)"),
                "fps": .int(format.frameRate),
            ]
        )
    }

    /// Stops the program tick, cancels every fill task, finishes the program
    /// stream, and clears the slots. Safe to call more than once.
    public func stop() {
        let (tickTask, fillTasks, continuation) = state.withLock { state in
            let taken = (state.tickTask, Array(state.fillTasks.values), state.programContinuation)
            state.tickTask = nil
            state.fillTasks.removeAll()
            state.slots.removeAll()
            state.programContinuation = nil
            return taken
        }
        tickTask?.cancel()
        for task in fillTasks {
            task.cancel()
        }
        continuation?.finish()
        eventBus.event("program.stopped", domain: .composition)
    }

    /// Stores one input's newest frame into its latest-wins slot.
    private func store(_ frame: CapturedFrame, for id: InputID) {
        state.withLock { $0.slots[id] = frame }
    }
}
