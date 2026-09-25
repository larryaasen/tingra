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
# The build goes to Xcode's own DerivedData — the same Tingra.app ⌘R builds —
# and the product's path is read from the build settings. It used a private
# derived-data folder under apps/tingra-app/.build until 2026-09-24, and that
# second Tingra.app carried a second copy of every embedded extension: macOS
# registers both, and each app then counts the other's copy as an extension
# awaiting approval (`plugin.availability unapproved=1`). ExtensionKit reports
# only that count, never which extension it is, so the app cannot tell a copy
# of its own Notes from a stranger's plug-in; one Tingra.app per Mac is the
# fix. Sharing the build also means alternating between ⌘R and this script no
# longer rebuilds everything. The cost: while Xcode is building, this script
# waits on, or is refused, the shared build database.
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
readonly -a build_args=(
    -project "$project"
    -scheme tingra-app
    -configuration "$config"
    -destination 'platform=macOS,arch=arm64'
)

echo "run-app: building Tingra ($config)…"
# The build's own status decides, not grep's: Xcode's DerivedData keeps the
# last good Tingra.app, so a build that failed would otherwise go on to launch
# a stale app as if nothing had happened.
set +e
xcodebuild build "${build_args[@]}" | grep -vE '^\s*$'
build_status=${PIPESTATUS[0]}
set -e
if (( build_status != 0 )); then
    echo "run-app: the build did not succeed (xcodebuild exited $build_status); see the errors above." >&2
    exit "$build_status"
fi

# Where Xcode put the product: its DerivedData folder is named after a hash
# of the project's path, so ask rather than guess.
products="$(xcodebuild -showBuildSettings "${build_args[@]}" 2>/dev/null \
    | awk -F ' = ' '/^ +BUILT_PRODUCTS_DIR = / { print $2; exit }')"
readonly app="$products/Tingra.app"
readonly executable="$app/Contents/MacOS/Tingra"
if [[ -z "$products" || ! -x "$executable" ]]; then
    echo "run-app: built app not found at '$app'." >&2
    exit 1
fi

# Re-sign with the stable identity only when the build left no real
# signature — a CODE_SIGNING_ALLOWED=NO build, or a Mac whose keychain has no
# certificate for the team (see sign-app.sh). This is Xcode's own product now,
# so a build Xcode signed is left exactly as Xcode signed it.
# A certificate signature names its chain in `Authority=` lines; an ad-hoc
# or linker signature, or none at all, has none. The details are read into a
# variable first: piped straight into `grep -q`, codesign dies of SIGPIPE when
# grep stops at the first match, and pipefail would report a signed app as
# unsigned.
signature="$(codesign -dvv "$app" 2>&1 || true)"
if ! grep -q '^Authority=' <<<"$signature"; then
    "$root/scripts/sign-app.sh" "$app"
fi

if [[ "$run" == "no" ]]; then
    echo "run-app: built and signed $app (not launched)."
    exit 0
fi

echo "run-app: launching $app (Ctrl-C to quit)…"
exec "$executable"
