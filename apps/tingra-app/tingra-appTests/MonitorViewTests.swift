//
//  MonitorViewTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-26.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit
import Testing
import TingraPlugInKit

@testable import TingraApp

/// A frame source whose picture state a test sets, counting how often the
/// monitor reads its frame — the read a skipped refresh never makes. It has
/// no frame, so a draw that reads it only clears, needing no drawable.
@MainActor
private final class ScriptedFrameSource: MonitorFrameSource {
    /// The state the source reports.
    var state: any Equatable = 0

    /// How many times the monitor read ``latest``.
    private(set) var frameReads = 0

    /// Always nil, counting the read.
    var latest: CVPixelBuffer? {
        frameReads += 1
        return nil
    }

    /// The scripted state.
    var pictureState: any Equatable { state }
}

/// Whether two picture states are equal — the comparison the monitor makes.
/// Not generic itself, so `#expect` can take it: the macro's expansion
/// keeps a generic call from opening the existential.
///
/// - Parameters:
///   - state: One state.
///   - other: The other.
/// - Returns: Whether they are equal; false across types.
private func isSame(_ state: any Equatable, _ other: any Equatable) -> Bool {
    matches(state, other)
}

/// ``isSame(_:_:)`` with the first state's type opened.
///
/// - Parameters:
///   - state: One state, its type opened.
///   - other: The other.
/// - Returns: Whether they are equal; false across types.
private func matches<State: Equatable>(_ state: State, _ other: any Equatable) -> Bool {
    (other as? State) == state
}

/// A small frame at `time`, in a fresh buffer or in `buffer` when given — a
/// pool handing a buffer back for a later frame.
///
/// - Parameters:
///   - time: The frame's presentation time, in seconds.
///   - buffer: The buffer to reuse, or nil for a new one.
/// - Returns: The frame.
private func frame(at time: Int64, in buffer: CVPixelBuffer? = nil) throws -> CapturedFrame {
    var created = buffer
    if created == nil {
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &created)
    }
    let pixelBuffer = try #require(created)
    return CapturedFrame(pixelBuffer: pixelBuffer, presentationTime: CMTime(value: time, timescale: 1))
}

/// A monitor redraws only when its picture changed (MonitorView, "Drawing
/// only a changed picture"): the frame stamp tells frames apart, each source
/// reports what its picture depends on, and the coordinator skips a refresh
/// whose state it already drew.
@Suite("MonitorView")
@MainActor
struct MonitorViewTests {
    @Test("a frame's stamp matches itself and differs for a later frame in the same pooled buffer")
    func stampTellsFramesApart() throws {
        let first = try frame(at: 1)
        let reused = try frame(at: 2, in: first.pixelBuffer)
        let other = try frame(at: 1)

        #expect(MonitorFrameStamp(first) == MonitorFrameStamp(first))
        #expect(MonitorFrameStamp(first) != MonitorFrameStamp(reused))
        #expect(MonitorFrameStamp(first) != MonitorFrameStamp(other))
    }

    @Test("the relay's picture state moves with every change and holds across reads")
    func relayStateFollowsChanges() throws {
        let relay = ProgramFrameRelay()
        let empty = relay.pictureState
        _ = relay.latest
        #expect(isSame(relay.pictureState, empty))

        relay.store(try frame(at: 1))
        let stored = relay.pictureState
        #expect(!isSame(stored, empty))
        _ = relay.latest
        #expect(isSame(relay.pictureState, stored))

        relay.setAccepting(false)
        let cleared = relay.pictureState
        #expect(!isSame(cleared, stored))

        relay.store(try frame(at: 2))
        #expect(isSame(relay.pictureState, cleared))
    }

    @Test(
        "a monitor draws once, then skips refreshes while the picture state holds",
        .enabled(if: MTLCreateSystemDefaultDevice() != nil)
    )
    func unchangedPictureIsSkipped() {
        let source = ScriptedFrameSource()
        let coordinator = MonitorView.Coordinator(source: source)
        let view = MTKView()

        for _ in 0..<3 {
            coordinator.draw(in: view)
        }

        #expect(source.frameReads == 1)
    }

    @Test(
        "a changed picture state draws again",
        .enabled(if: MTLCreateSystemDefaultDevice() != nil)
    )
    func changedPictureIsDrawn() {
        let source = ScriptedFrameSource()
        let coordinator = MonitorView.Coordinator(source: source)
        let view = MTKView()
        coordinator.draw(in: view)

        source.state = 1
        coordinator.draw(in: view)
        coordinator.draw(in: view)

        #expect(source.frameReads == 2)
    }

    @Test(
        "a resized drawable draws again with the picture state unchanged",
        .enabled(if: MTLCreateSystemDefaultDevice() != nil)
    )
    func resizedDrawableIsDrawn() {
        let source = ScriptedFrameSource()
        let coordinator = MonitorView.Coordinator(source: source)
        let view = MTKView()
        coordinator.draw(in: view)

        coordinator.mtkView(view, drawableSizeWillChange: CGSize(width: 64, height: 36))
        coordinator.draw(in: view)

        #expect(source.frameReads == 2)
    }

    @Test(
        "a source swapped for one whose state is of another type draws",
        .enabled(if: MTLCreateSystemDefaultDevice() != nil)
    )
    func swappedSourceIsDrawn() {
        let first = ScriptedFrameSource()
        let second = ScriptedFrameSource()
        second.state = "another kind"
        let coordinator = MonitorView.Coordinator(source: first)
        let view = MTKView()
        coordinator.draw(in: view)

        coordinator.source = second
        coordinator.draw(in: view)

        #expect(second.frameReads == 1)
    }

    @Test(
        "a thumbnail samples at 15 frames a second, and a monitor with no maximum asks for the fastest program's rate, above a ProMotion display's"
    )
    func samplingRates() {
        #expect(MonitorView.framesPerSecond(maximum: MonitorView.thumbnailFramesPerSecond) == 15)
        #expect(MonitorView.framesPerSecond(maximum: nil) == MonitorView.displayFramesPerSecond)
        #expect(MonitorView.displayFramesPerSecond == ProgramFormatChoice.maximumFrameRate)
        #expect(MonitorView.displayFramesPerSecond >= 120)
    }

    @Test("an input tile's and the layer monitor's picture states hold while nothing is delivering")
    func modelSourcesHoldWhileIdle() throws {
        let suiteName = "MonitorViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = EngineModel(
            monitor: SilentMonitor(), snapshotPreferences: SnapshotPreferences(defaults: defaults),
            recordingPreferences: RecordingPreferences(defaults: defaults))
        let input = InputFrameSource(model: model, id: InputID(rawValue: "cam-1"))
        let layer = LayerMonitorSource(model: model)

        #expect(isSame(input.pictureState, input.pictureState))
        #expect(isSame(layer.pictureState, layer.pictureState))
    }
}
