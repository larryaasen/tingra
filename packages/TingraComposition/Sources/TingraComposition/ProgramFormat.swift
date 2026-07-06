//
//  ProgramFormat.swift
//  TingraComposition
//
//  Created by Larry Aasen on 2026-07-06.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

/// The program's output geometry and cadence: the size every composited
/// program frame is rendered at, and the rate the program tick fires.
///
/// The compositor renders into buffers of exactly this size (captured
/// frames are scaled to fit their layer's destination rect), so the program
/// frame is resolution-stable regardless of the inputs' native sizes — the
/// one conversion point ARCHITECTURE.md ("Color and pixel format
/// conventions") calls for on the composition side.
public struct ProgramFormat: Sendable, Equatable {
    /// The program width in pixels. Kept even — 4:2:0 delivery requires it
    /// (ARCHITECTURE.md).
    public let width: Int

    /// The program height in pixels. Kept even — 4:2:0 delivery requires it.
    public let height: Int

    /// The program frame rate: how often the program tick fires and a
    /// composited frame is produced.
    public let frameRate: Int

    /// Creates a program format. Defaults match the CLI's program defaults
    /// (1920x1080 at 30 fps, see CLI.md "Compression").
    ///
    /// - Parameters:
    ///   - width: The program width in pixels.
    ///   - height: The program height in pixels.
    ///   - frameRate: The program frame rate.
    public init(width: Int = 1920, height: Int = 1080, frameRate: Int = 30) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}
