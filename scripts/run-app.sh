#!/bin/bash
#
#  run-app.sh
#  tingra
#
#  Created by Larry Aasen on 2026-07-06.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# Builds apps/tingra, wraps it in a minimal `tingra.app`, signs it with a stable
# identity, and runs it — the terminal counterpart to running the app from
# Xcode, for developers who work from the command line.
#
# Why a bundle and not just the bare executable:
#   - macOS TCC keys Screen Recording / Camera / Microphone grants to the code
#     signature. Signing (via scripts/sign-app.sh) with a real certificate and a
#     stable bundle identifier makes the grant persist across rebuilds instead
#     of re-prompting every run (an ad-hoc build's cdhash changes each build).
#   - macOS requires the Info.plist usage-description strings before it will
#     grant Camera/Microphone — without NSCameraUsageDescription /
#     NSMicrophoneUsageDescription the process is *killed* on first camera/mic
#     use. Screen Recording needs no Info.plist key (it is TCC-only).
# Running the bundle's executable directly (rather than `open`ing the app) keeps
# the process in the foreground so the event log streams to this terminal (the
# app logs to stdout via ConsoleEventSink) and Ctrl-C stops it.
#
# This is a DEVELOPER-CONVENIENCE helper. The shipping build is a Developer ID
# signed, notarized `.app` per CLI.md "Distribution"; this is not that pipeline.
#
# Usage: scripts/run-app.sh [--release] [--no-run]
#   --release   Build the release configuration (default: debug).
#   --no-run    Build, bundle, and sign, but do not launch (build/CI checks).
set -euo pipefail

config="debug"
run="yes"
for arg in "$@"; do
    case "$arg" in
        --release) config="release" ;;
        --no-run) run="no" ;;
        -h | --help)
            echo "usage: scripts/run-app.sh [--release] [--no-run]"
            exit 0
            ;;
        *)
            echo "run-app: unknown argument '$arg' (see --help)." >&2
            exit 64
            ;;
    esac
done

readonly root="$(cd "$(dirname "$0")/.." && pwd)"
readonly package="$root/apps/tingra"

echo "run-app: building tingra ($config)…"
swift build --package-path "$package" -c "$config"

bin_dir="$(swift build --package-path "$package" -c "$config" --show-bin-path)"
readonly executable="$bin_dir/tingra"
if [[ ! -x "$executable" ]]; then
    echo "run-app: built executable not found at '$executable'." >&2
    exit 1
fi

# Assemble a fresh tingra.app next to the build product.
readonly app="$bin_dir/tingra.app"
readonly macos_dir="$app/Contents/MacOS"
rm -rf "$app"
mkdir -p "$macos_dir"
cp "$executable" "$macos_dir/tingra"

# The Info.plist: a stable bundle identifier (TCC) and the Camera/Microphone
# usage descriptions macOS requires before granting access. Kept in English —
# localizing Info.plist strings (InfoPlist.strings) belongs to the release
# packaging, not this dev helper.
cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tingra</string>
    <key>CFBundleDisplayName</key>
    <string>Tingra</string>
    <key>CFBundleIdentifier</key>
    <string>com.moonwink.tingra</string>
    <key>CFBundleExecutable</key>
    <string>tingra</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Tingra composites your camera into the program.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Tingra mixes your microphone into the program.</string>
</dict>
</plist>
PLIST

printf 'APPL????' >"$app/Contents/PkgInfo"

# Sign the whole bundle with the stable identity (reuses sign-app.sh, whose
# identifier matches CFBundleIdentifier above).
"$root/scripts/sign-app.sh" "$app"

if [[ "$run" == "no" ]]; then
    echo "run-app: built and signed $app (not launched)."
    exit 0
fi

echo "run-app: launching $app (Ctrl-C to quit)…"
exec "$macos_dir/tingra"
