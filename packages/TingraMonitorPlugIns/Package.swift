// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraMonitorPlugIns
//
//  Created by Larry Aasen on 2026-11-14.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The first-party monitor overlays (PLUGINS.md, Decisions 52–57): safe
// areas, crop guides, a center cross, a rule-of-thirds grid, and a tally
// border, which a monitor draws for the operator alone and which never
// reach the program. Core Image only, registered through the
// MonitorOverlayRegistering seam, so the package depends on the protocol
// package alone, never the engine. Linked by the app alone, since nothing
// else draws a monitor (Decision 56).
let package = Package(
    name: "TingraMonitorPlugIns",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraMonitorPlugIns", targets: ["TingraMonitorPlugIns"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraMonitorPlugIns",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraMonitorPlugInsTests", dependencies: ["TingraMonitorPlugIns"]),
    ]
)
