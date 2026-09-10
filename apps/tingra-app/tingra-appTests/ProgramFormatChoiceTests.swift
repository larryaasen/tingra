//
//  ProgramFormatChoiceTests.swift
//  tingra-app
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import Testing
import TingraComposition

@testable import TingraApp

@Suite("ProgramFormatChoice")
@MainActor
struct ProgramFormatChoiceTests {
    @Test("every named size is even on both axes — 4:2:0 delivery requires it — and at least the minimum")
    func namedSizesAreEven() {
        for size in ProgramSize.allCases {
            #expect(size.width.isMultiple(of: 2), "\(size)")
            #expect(size.height.isMultiple(of: 2), "\(size)")
            #expect(size.width >= ProgramFormatChoice.minimumDimension)
            #expect(size.height >= ProgramFormatChoice.minimumDimension)
            #expect(ProgramFormatChoice.problem(width: size.width, height: size.height, frameRate: 30) == nil)
        }
    }

    @Test("named sizes carry distinct dimensions and 1080p is the default format's")
    func namedSizesAreDistinct() {
        let dimensions = Set(ProgramSize.allCases.map { "\($0.width)x\($0.height)" })
        #expect(dimensions.count == ProgramSize.allCases.count)
        #expect(ProgramSize.named(matching: ProgramFormat()) == .p1080)
    }

    @Test("a format's named size is found by dimensions alone, at any rate; a custom size finds none")
    func namedSizeLookup() {
        #expect(ProgramSize.named(matching: ProgramFormat(width: 3840, height: 2160, frameRate: 60)) == .uhd4K)
        #expect(ProgramSize.named(matching: ProgramFormat(width: 1080, height: 1920, frameRate: 24)) == .vertical1080)
        #expect(ProgramSize.named(matching: ProgramFormat(width: 7680, height: 4320, frameRate: 30)) == nil)
        #expect(ProgramSize.named(matching: ProgramFormat(width: 1920, height: 1088, frameRate: 30)) == nil)
    }

    @Test("a named size at a rate is the format with those dimensions and that rate")
    func namedSizeFormat() {
        #expect(ProgramSize.p720.format(at: 50) == ProgramFormat(width: 1280, height: 720, frameRate: 50))
    }

    @Test("the frame rate menu offers the whole-number film, PAL, and NTSC rates, ascending")
    func frameRates() {
        #expect(ProgramFormatChoice.frameRates == [24, 25, 30, 50, 60])
        for rate in ProgramFormatChoice.frameRates {
            #expect(ProgramFormatChoice.problem(width: 1920, height: 1080, frameRate: rate) == nil)
        }
    }

    @Test("the status bar label reads size and rate verbatim")
    func statusLabel() {
        #expect(ProgramFormatChoice.label(for: ProgramFormat()) == "1920×1080 · 30 fps")
        #expect(
            ProgramFormatChoice.label(for: ProgramFormat(width: 1080, height: 1920, frameRate: 60))
                == "1080×1920 · 60 fps")
    }

    @Test("a change is refused while streaming or recording, streaming named first, and allowed otherwise")
    func refusal() {
        #expect(ProgramFormatChoice.refusal(isStreaming: false, isRecording: false) == nil)
        #expect(ProgramFormatChoice.refusal(isStreaming: true, isRecording: false) == "streaming")
        #expect(ProgramFormatChoice.refusal(isStreaming: false, isRecording: true) == "recording")
        #expect(ProgramFormatChoice.refusal(isStreaming: true, isRecording: true) == "streaming")
    }

    @Test("a typed format's first broken rule is reported: too small, then odd, then the rate")
    func problems() {
        #expect(ProgramFormatChoice.problem(width: 1920, height: 1080, frameRate: 30) == nil)
        #expect(ProgramFormatChoice.problem(width: 7680, height: 4320, frameRate: 30) == nil)
        #expect(ProgramFormatChoice.problem(width: 1921, height: 1080, frameRate: 30) == .oddDimension)
        #expect(ProgramFormatChoice.problem(width: 1920, height: 1081, frameRate: 30) == .oddDimension)
        #expect(ProgramFormatChoice.problem(width: 8, height: 1080, frameRate: 30) == .tooSmall)
        #expect(ProgramFormatChoice.problem(width: 0, height: 0, frameRate: 30) == .tooSmall)
        #expect(ProgramFormatChoice.problem(width: 15, height: 1080, frameRate: 30) == .tooSmall)
        #expect(ProgramFormatChoice.problem(width: 1920, height: 1080, frameRate: 0) == .badFrameRate)
        #expect(ProgramFormatChoice.problem(width: 1920, height: 1080, frameRate: 241) == .badFrameRate)
        #expect(ProgramFormatChoice.problem(width: 1920, height: 1080, frameRate: 240) == nil)
    }

    @Test("every problem carries a non-empty message")
    func problemMessages() {
        for problem in [ProgramFormatProblem.oddDimension, .tooSmall, .badFrameRate] {
            #expect(!problem.message.isEmpty)
        }
    }
}
