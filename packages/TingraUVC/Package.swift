// swift-tools-version: 6.3.3
//
//  Package.swift
//  TingraUVC
//
//  Created by Larry Aasen on 2026-10-27.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// A general-purpose USB Video Class control library for the Mac: lists the
// connected UVC cameras and reads and sets their standard controls
// (brightness, contrast, white balance, exposure, focus, zoom, ...) through
// Apple's IOUSBHost. Standalone on purpose — it depends on no other Tingra
// package, so any Mac app can import it (see docs/UVC.md).
let package = Package(
    name: "TingraUVC",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TingraUVC", targets: ["TingraUVC"])
    ],
    targets: [
        .target(name: "TingraUVC"),
        .testTarget(name: "TingraUVCTests", dependencies: ["TingraUVC"]),
    ]
)
