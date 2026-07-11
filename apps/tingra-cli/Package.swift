// swift-tools-version: 6.3.3
//
//  Package.swift
//  tingra-cli
//
//  Created by Larry Aasen on 2026-07-03.
//  Copyright © 2026 Larry Aasen.
//  SPDX-License-Identifier: MIT
//

import PackageDescription

// The headless front end over the engine (see CLI.md). The target is named
// TingraCLI (Swift module names cannot contain a hyphen); the product keeps
// the user-facing name `tingra-cli`.
let package = Package(
    name: "tingra-cli",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "tingra-cli", targets: ["TingraCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(path: "../../packages/TingraCapturePlugIns"),
        .package(path: "../../packages/TingraEventBus"),
        .package(path: "../../packages/TingraGeneratorPlugIns"),
        .package(path: "../../packages/TingraHost"),
        .package(path: "../../packages/TingraMCP"),
        .package(path: "../../packages/TingraOutputPlugIns"),
        .package(path: "../../packages/TingraPlugInKit"),
        .package(path: "../../packages/TingraRecordingPlugIns"),
    ],
    targets: [
        .executableTarget(
            name: "TingraCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TingraCapturePlugIns", package: "TingraCapturePlugIns"),
                .product(name: "TingraEventBus", package: "TingraEventBus"),
                .product(name: "TingraGeneratorPlugIns", package: "TingraGeneratorPlugIns"),
                .product(name: "TingraHost", package: "TingraHost"),
                .product(name: "TingraMCP", package: "TingraMCP"),
                .product(name: "TingraOutputPlugIns", package: "TingraOutputPlugIns"),
                .product(name: "TingraPlugInKit", package: "TingraPlugInKit"),
                .product(name: "TingraRecordingPlugIns", package: "TingraRecordingPlugIns"),
            ],
            // A bare executable has no bundle, so the Info.plist (bundle id,
            // version, TCC usage descriptions) is embedded in the binary's
            // __TEXT,__info_plist section (see CLI.md, "Distribution"). The
            // path is resolved relative to the package root, where the linker
            // runs. unsafeFlags is sanctioned here: tingra-cli is a leaf
            // product nothing depends on.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        ),
        .testTarget(name: "TingraCLITests", dependencies: ["TingraCLI"]),
    ]
)
