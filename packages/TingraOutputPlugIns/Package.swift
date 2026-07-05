// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraOutputPlugIns
//
//  Created by Larry Aasen on 2026-07-04.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The first party streaming output plug-in: the HaishinKit backed
// StreamingService behind the output seam. This is the only package in the
// monorepo that imports HaishinKit (RTMP connection handling, muxing, and
// internal VideoToolbox compression — the standardized, undifferentiated
// work ARCHITECTURE.md delegates); everything else sees only the
// StreamingService protocol. Registration goes through the
// OutputRegistering seam, so the package depends on the protocol package
// alone, never the engine.
let package = Package(
    name: "TingraOutputPlugIns",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraOutputPlugIns", targets: ["TingraOutputPlugIns"])
    ],
    dependencies: [
        .package(url: "https://github.com/HaishinKit/HaishinKit.swift", from: "2.2.5"),
        // HaishinKit's own logging façade — imported only to route its
        // internal console logging into OSLog, keeping stdout/stderr clean
        // for the CLI's scripting contract (see HaishinKitLogging.swift).
        .package(url: "https://github.com/shogo4405/Logboard.git", from: "2.6.0"),
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraOutputPlugIns",
            dependencies: [
                .product(name: "HaishinKit", package: "HaishinKit.swift"),
                .product(name: "RTMPHaishinKit", package: "HaishinKit.swift"),
                .product(name: "Logboard", package: "Logboard"),
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraOutputPlugInsTests", dependencies: ["TingraOutputPlugIns"]),
    ]
)
