// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraEffectPlugIns
//
//  Created by Larry Aasen on 2026-07-20.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The first-party effect plug-ins (ARCHITECTURE.md, "The effect seam"):
// the audio staples — gain and the high-/low-pass filters — as thin
// conformances against the shared effect seam; per-layer video effects
// join in the seam's second iteration. Pure DSP over the seam's native
// currencies, fully deterministic in tests — no hardware, no TCC.
// Registration goes through the EffectRegistering seam, so the package
// depends on the protocol package alone, never the engine (see
// ARCHITECTURE.md).
let package = Package(
    name: "TingraEffectPlugIns",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraEffectPlugIns", targets: ["TingraEffectPlugIns"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraEffectPlugIns",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraEffectPlugInsTests", dependencies: ["TingraEffectPlugIns"]),
    ]
)
