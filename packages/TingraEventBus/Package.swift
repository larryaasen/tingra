// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraEventBus
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

let package = Package(
    name: "TingraEventBus",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraEventBus", targets: ["TingraEventBus"])
    ],
    targets: [
        .target(name: "TingraEventBus"),
        .testTarget(name: "TingraEventBusTests", dependencies: ["TingraEventBus"]),
    ]
)
