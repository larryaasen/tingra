// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraRecordingPlugIns
//
//  Created by Larry Aasen on 2026-07-05.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The first party local recording plug-in: the AVAssetWriter backed
// RecordingService behind the recording seam (see ARCHITECTURE.md,
// Compression: local recording via AVAssetWriter, a compression sink
// parallel to streaming output). It lives in its own package rather than
// folding into TingraOutputPlugIns so that package keeps its defining
// property — the only one importing HaishinKit — intact: recording imports
// only AVFoundation, needs neither HaishinKit nor Logboard, and is a
// distinct capability from streaming. Registration goes through the same
// OutputRegistering seam as streaming output, so the package depends on the
// protocol package alone, never the engine.
let package = Package(
    name: "TingraRecordingPlugIns",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraRecordingPlugIns", targets: ["TingraRecordingPlugIns"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraRecordingPlugIns",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraRecordingPlugInsTests", dependencies: ["TingraRecordingPlugIns"]),
    ]
)
