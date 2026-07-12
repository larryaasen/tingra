// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraAudio
//
//  Created by Larry Aasen on 2026-07-12.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The audio engine library: the clock-paced mixer that combines every audio
// input into the program mix, one channel strip per input (GLOSSARY.md,
// "Mixer", "Channel strip"). A host-side engine library beside
// TingraComposition — the Audio engine service, not a plug-in (audio effects
// and taps plug into it later) — so it depends only on the protocol package
// and the event bus, never the host, and stays testable in isolation with a
// synthetic clock and generator inputs (see ARCHITECTURE.md, "Audio", and
// CLOCK.md).
let package = Package(
    name: "TingraAudio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraAudio", targets: ["TingraAudio"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraAudio",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraAudioTests", dependencies: ["TingraAudio"]),
    ]
)
