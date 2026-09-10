// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraMediaPlugIns
//
//  Created by Larry Aasen on 2026-09-10.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

let package = Package(
    name: "TingraMediaPlugIns",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraMediaPlugIns", targets: ["TingraMediaPlugIns"])
    ],
    dependencies: [
        .package(path: "../TingraEventBus"),
        .package(path: "../TingraPlugInKit"),
    ],
    targets: [
        .target(
            name: "TingraMediaPlugIns",
            dependencies: [
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
            ]
        ),
        .testTarget(name: "TingraMediaPlugInsTests", dependencies: ["TingraMediaPlugIns"]),
    ]
)
