//
//  StopwatchTests.swift
//  TingraGeneratorPlugIns
//
//  Created by Claude on 2026-11-11.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import CoreMedia
import Testing
import TingraPlugInKit

@testable import TingraGeneratorPlugIns

@Suite("Stopwatch")
struct StopwatchTests {
    @Test("a running stopwatch measures from the master clock time it started at")
    func runningMeasuresFromStart() {
        let stopwatch = Stopwatch(state: .running, at: seconds(100))

        #expect(stopwatch.elapsed(at: seconds(100)) == .zero)
        #expect(stopwatch.elapsed(at: seconds(165)) == seconds(65))
    }

    @Test("a time before the start adds nothing, never a negative amount")
    func timeBeforeStartIsZero() {
        let stopwatch = Stopwatch(state: .running, at: seconds(100))

        #expect(stopwatch.elapsed(at: seconds(40)) == .zero)
    }

    @Test("a stopwatch created reset or paused holds at zero")
    func createdHeldStaysAtZero() {
        #expect(Stopwatch(state: .reset, at: seconds(5)).elapsed(at: seconds(500)) == .zero)
        #expect(Stopwatch(state: .paused, at: seconds(5)).elapsed(at: seconds(500)) == .zero)
    }

    @Test("pausing holds the elapsed time, and running again resumes from it")
    func pauseHoldsAndResumeContinues() {
        var stopwatch = Stopwatch(state: .running, at: seconds(0))

        stopwatch.setState(.paused, at: seconds(30))
        #expect(stopwatch.elapsed(at: seconds(30)) == seconds(30))
        #expect(stopwatch.elapsed(at: seconds(90)) == seconds(30))

        stopwatch.setState(.running, at: seconds(100))
        #expect(stopwatch.elapsed(at: seconds(100)) == seconds(30))
        #expect(stopwatch.elapsed(at: seconds(110)) == seconds(40))
    }

    @Test("reset returns to zero and holds there until running again")
    func resetReturnsToZero() {
        var stopwatch = Stopwatch(state: .running, at: seconds(0))

        stopwatch.setState(.reset, at: seconds(45))
        #expect(stopwatch.elapsed(at: seconds(200)) == .zero)

        stopwatch.setState(.running, at: seconds(300))
        #expect(stopwatch.elapsed(at: seconds(307)) == seconds(7))
    }

    @Test("applying the state it already holds changes nothing, so a re-sent payload never restarts the count")
    func sameStateIsIdempotent() {
        var stopwatch = Stopwatch(state: .running, at: seconds(10))
        let before = stopwatch

        stopwatch.setState(.running, at: seconds(50))

        #expect(stopwatch == before)
        #expect(stopwatch.elapsed(at: seconds(60)) == seconds(50))
    }

    @Test("stopwatches in different states are not equal")
    func differentStatesAreNotEqual() {
        #expect(Stopwatch(state: .running, at: .zero) != Stopwatch(state: .paused, at: .zero))
        #expect(Stopwatch(state: .running, at: .zero) == Stopwatch(state: .running, at: .zero))
    }
}

@Suite("RunState")
struct RunStateTests {
    @Test("the state parameter is a choice of Reset, Running, and Paused, defaulting to Running")
    func parameterShape() {
        let parameter = RunState.parameter

        #expect(parameter.key == "state")
        #expect(parameter.kind == .choice)
        #expect(parameter.choices.map(\.name) == ["Reset", "Running", "Paused"])
        #expect(parameter.choices.map(\.value) == [0, 1, 2])
        #expect(parameter.defaultValue == 1)
    }

    @Test("a payload's number selects the state")
    func readsStateFromPayload() {
        #expect(RunState.value(in: ["state": .double(0)]) == .reset)
        #expect(RunState.value(in: ["state": .int(1)]) == .running)
        #expect(RunState.value(in: ["state": .double(2)]) == .paused)
    }

    @Test("an omitted key, a value no state has, or a value of the wrong type reads as Running")
    func unknownValuesReadAsDefault() {
        #expect(RunState.value(in: [:]) == .running)
        #expect(RunState.value(in: ["state": .double(7)]) == .running)
        #expect(RunState.value(in: ["state": .string("paused")]) == .running)
    }
}

@Suite("ClockText")
struct ClockTextTests {
    @Test("below an hour the text is MM:SS")
    func minutesAndSeconds() {
        #expect(ClockText.string(forSeconds: 0) == "00:00")
        #expect(ClockText.string(forSeconds: 9) == "00:09")
        #expect(ClockText.string(forSeconds: 65) == "01:05")
        #expect(ClockText.string(forSeconds: 3599) == "59:59")
    }

    @Test("from an hour up the text is H:MM:SS")
    func hoursMinutesAndSeconds() {
        #expect(ClockText.string(forSeconds: 3600) == "1:00:00")
        #expect(ClockText.string(forSeconds: 3725) == "1:02:05")
        #expect(ClockText.string(forSeconds: 86_399) == "23:59:59")
        #expect(ClockText.string(forSeconds: 360_000) == "100:00:00")
    }

    @Test("a negative count reads as zero")
    func negativeReadsAsZero() {
        #expect(ClockText.string(forSeconds: -5) == "00:00")
    }

    @Test("milliseconds round to the nearest, so a hair short of a second still counts as it")
    func millisecondsRound() {
        #expect(ClockText.milliseconds(inSeconds: 0.9999999) == 1000)
        #expect(ClockText.milliseconds(inSeconds: 1.2344) == 1234)
        #expect(ClockText.milliseconds(inSeconds: -2) == -2000)
    }

    @Test("a duration that is not finite, or too long to count, is zero rather than a trap")
    func unboundedDurationsAreZero() {
        #expect(ClockText.milliseconds(inSeconds: .infinity) == 0)
        #expect(ClockText.milliseconds(inSeconds: .nan) == 0)
        #expect(ClockText.milliseconds(inSeconds: 1e300) == 0)
    }
}
