// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraGeneratorPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The first party generator plug-ins: SMPTE color bars, an alignment
// pattern, and PLUGE (video), plus the 440 Hz test tone (audio).
// Generators are the permanent CI test surface — they synthesize frames
// from the injected clock, so no camera, microphone, or TCC authorization
// is ever needed. Registration goes through the InputRegistering seam, so
// the package depends on the protocol package alone, never the engine (see
// ARCHITECTURE.md).
let package = Package(
    name: "TingraGeneratorPlugIns",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraGeneratorPlugIns", targets: ["TingraGeneratorPlugIns"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraGeneratorPlugIns",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraGeneratorPlugInsTests", dependencies: ["TingraGeneratorPlugIns"]),
    ]
)
