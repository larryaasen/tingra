// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraCapturePlugIns
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The first party capture plug-ins: camera and microphone discovery now,
// the full inputs at roadmap step 2. AVFoundation is imported only inside
// this package, behind the Input seam; registration goes through the
// InputRegistering seam, so the package depends on the protocol package
// alone, never the engine (see ARCHITECTURE.md).
let package = Package(
    name: "TingraCapturePlugIns",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraCapturePlugIns", targets: ["TingraCapturePlugIns"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraCapturePlugIns",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraCapturePlugInsTests", dependencies: ["TingraCapturePlugIns"]),
    ]
)
