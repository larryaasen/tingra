//
//  CompressionSettingsTests.swift
//  tingra-appTests
//
//  Created by Larry Aasen on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TingraHost
import TingraPlugInKit

@testable import TingraApp

/// The model's compression choices: what the stream and a recording are
/// configured with, and where each choice persists.
@Suite("EngineModel compression settings")
@MainActor
struct CompressionSettingsTests {
    /// A model over throwaway preferences and a silent monitor, so the test
    /// touches no device and none of the developer's settings.
    private func makeModel(suiteName: String) throws -> EngineModel {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return EngineModel(
            monitor: SilentMonitor(), snapshotPreferences: SnapshotPreferences(defaults: defaults),
            recordingPreferences: RecordingPreferences(defaults: defaults),
            streamingPreferences: StreamingPreferences(defaults: defaults))
    }

    /// A fresh suite name for one test.
    private func makeSuiteName() -> String { "CompressionSettingsTests-\(UUID().uuidString)" }

    @Test("a new model records H.264 and compresses both sinks' sound at 160 kbps")
    func aNewModelUsesTheDefaults() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)

        #expect(model.recordingVideoCodec == .h264)
        #expect(model.recordingConfiguration.videoCodec == .h264)
        #expect(model.recordingConfiguration.audioBitsPerSecond == 160_000)
        #expect(model.streamConfiguration.videoCodec == .h264)
        #expect(model.streamConfiguration.audioBitsPerSecond == 160_000)
    }

    @Test("choosing HEVC records HEVC at a lower video bit rate, and leaves the stream on H.264")
    func hevcLowersTheRecordingBitRate() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)
        let h264 = model.recordingConfiguration

        model.setRecordingVideoCodec(.hevc)

        let hevc = model.recordingConfiguration
        #expect(hevc.videoCodec == .hevc)
        #expect(hevc.videoBitsPerSecond < h264.videoBitsPerSecond)
        #expect(
            hevc.videoBitsPerSecond
                == CompressionChoices.videoBitsPerSecond(
                    width: hevc.width, height: hevc.height, frameRate: hevc.frameRate, codec: .hevc))
        #expect(hevc.width == h264.width)
        #expect(hevc.height == h264.height)
        #expect(hevc.frameRate == h264.frameRate)
        #expect(model.streamConfiguration.videoCodec == .h264)
        #expect(model.streamConfiguration.videoBitsPerSecond == h264.videoBitsPerSecond)
    }

    @Test("the recording's audio bit rate and the stream's are set apart")
    func audioBitRatesAreIndependent() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)

        model.setRecordingAudioBitsPerSecond(320_000)
        #expect(model.recordingConfiguration.audioBitsPerSecond == 320_000)
        #expect(model.streamConfiguration.audioBitsPerSecond == 160_000)

        model.setStreamAudioBitsPerSecond(256_000)
        #expect(model.streamConfiguration.audioBitsPerSecond == 256_000)
        #expect(model.recordingConfiguration.audioBitsPerSecond == 320_000)
    }

    @Test("a rate off the menu becomes the nearest one on it")
    func aRateOffTheMenuSnaps() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)

        model.setStreamAudioBitsPerSecond(130_000)
        model.setRecordingAudioBitsPerSecond(5_000_000)

        #expect(model.streamAudioBitsPerSecond == 128_000)
        #expect(model.recordingAudioBitsPerSecond == 320_000)
    }

    @Test("the choices persist, and a new model over the same preferences starts with them")
    func choicesPersist() throws {
        let suiteName = makeSuiteName()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let model = try makeModel(suiteName: suiteName)

        model.setRecordingVideoCodec(.hevc)
        model.setRecordingAudioBitsPerSecond(192_000)
        model.setStreamAudioBitsPerSecond(96_000)

        let next = try makeModel(suiteName: suiteName)
        #expect(next.recordingVideoCodec == .hevc)
        #expect(next.recordingAudioBitsPerSecond == 192_000)
        #expect(next.streamAudioBitsPerSecond == 96_000)
    }

    @Test("the picker reads a rate in whole kilobits per second")
    func pickerLabels() {
        #expect(AudioBitRatePicker.label(for: 160_000) == "160 kbps")
        #expect(AudioBitRatePicker.label(for: 96_000) == "96 kbps")
        #expect(AudioBitRatePicker.label(for: 1_536_000) == "1536 kbps")
    }

    @Test("each codec has its proper name")
    func codecNames() {
        #expect(RecordingSettingsView.name(of: .h264) == "H.264")
        #expect(RecordingSettingsView.name(of: .hevc) == "HEVC")
    }
}
