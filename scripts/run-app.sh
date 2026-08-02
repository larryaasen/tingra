#!/bin/bash
#
#  run-app.sh
#  tingra
#
#  Created by Larry Aasen on 2026-07-06.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# Builds apps/tingra-app and runs it in the foreground — the terminal
# counterpart to ⌘R in Xcode, for developers who work from the command line.
#
# Why this survived the move to an Xcode app target: the target itself now
# supplies the bundle, the Info.plist usage descriptions, and a stable
# signature, so none of that is scripted here any more. What `xcodebuild`
# alone does not do is run the app attached to this terminal. Launching the
# bundle's executable directly (rather than `open`ing the app) keeps the
# process in the foreground so the event log streams here — the app logs to
# stdout via ConsoleEventSink — and Ctrl-C stops it.
#
# The build goes to a fixed derived-data path under apps/tingra-app/.build
# (already git-ignored) rather than Xcode's shared DerivedData, so the product
# path is deterministic without parsing build settings. The trade-off is a
# build cache separate from Xcode's: alternating between ⌘R and this script
# rebuilds each time.
#
# This is a DEVELOPER-CONVENIENCE helper. The shipping build is a Developer ID
# signed, notarized `.app` per CLI.md "Distribution"; this is not that pipeline.
#
# Usage: scripts/run-app.sh [--release] [--no-run]
#   --release   Build the release configuration (default: debug).
#   --no-run    Build and sign, but do not launch (build/CI checks).
set -euo pipefail

config="Debug"
run="yes"
for arg in "$@"; do
    case "$arg" in
        --release) config="Release" ;;
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
readonly project="$root/apps/tingra-app/tingra-app.xcodeproj"
readonly derived="$root/apps/tingra-app/.build/DerivedData"

echo "run-app: building Tingra ($config)…"
xcodebuild build \
    -project "$project" \
    -scheme tingra-app \
    -configuration "$config" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" \
    | grep -vE '^\s*$' || true

readonly app="$derived/Build/Products/$config/Tingra.app"
readonly executable="$app/Contents/MacOS/Tingra"
if [[ ! -x "$executable" ]]; then
    echo "run-app: built app not found at '$app'." >&2
    exit 1
fi

# Re-sign with the stable identity. Xcode's automatic signing already produces
# a stable designated requirement, so this is belt-and-braces — it matters on a
# machine where automatic signing did not resolve a team (see sign-app.sh).
"$root/scripts/sign-app.sh" "$app"

if [[ "$run" == "no" ]]; then
    echo "run-app: built and signed $app (not launched)."
    exit 0
fi

echo "run-app: launching $app (Ctrl-C to quit)…"
exec "$executable"
