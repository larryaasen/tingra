#!/bin/bash
#
#  sign-app.sh
#  tingra
#
#  Created by Larry Aasen on 2026-07-06.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# Re-signs the built `tingra` executable with a stable code-signing identity so
# macOS TCC permission grants (Screen Recording, Camera, Microphone) persist
# across rebuilds.
#
# Why this is needed: `swift build` and Xcode ad-hoc sign an SPM executable by
# default. An ad-hoc signature's designated requirement is the binary's cdhash,
# which changes on every build — so TCC treats each rebuild as a brand-new app
# and re-prompts, even though the previous build's toggle still shows ON. Signing
# with a real certificate makes the requirement identifier + certificate based
# instead, so a single grant sticks across rebuilds.
#
# This is a DEVELOPER-CONVENIENCE step only. The shipping build is Developer ID
# signed (hardened runtime) and notarized per CLI.md "Distribution"; this script
# is not that pipeline.
#
# Usage:
#   - Automatically, as the `tingra` scheme's build post-action in Xcode (it
#     reads $BUILT_PRODUCTS_DIR from the build environment).
#   - Manually after `swift build` in apps/tingra: `scripts/sign-app.sh`.
#   - With an explicit target to sign (a bare executable or a `.app` bundle) as
#     the first argument: `scripts/sign-app.sh path/to/tingra.app` — this is how
#     `scripts/run-app.sh` signs the bundle it assembles.
#
# Override the signing identity with TINGRA_SIGN_IDENTITY; otherwise the first
# available code-signing identity in the keychain is used.
set -euo pipefail

# The stable bundle identifier the grant is keyed to (under com.moonwink.tingra
# per CLAUDE.md). Kept constant so the designated requirement never drifts.
readonly BUNDLE_ID="com.moonwink.tingra"

# Resolve the signing identity: an explicit override, else the first
# code-signing certificate in the keychain (Larry's is "Apple Development:
# Larry Aasen").
IDENTITY="${TINGRA_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | grep -o '"[^"]*"' | head -n1 | tr -d '"')"
fi

# Locate the target to sign — a bare executable or a `.app` bundle. An explicit
# first argument wins (run-app.sh passes the bundle path); otherwise prefer
# Xcode's build output (this script runs as a scheme build post-action, where
# $BUILT_PRODUCTS_DIR is set) and fall back to the `swift build` product path so
# the script also works from the command line.
target="${1:-}"
if [[ -z "$target" ]]; then
    if [[ -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
        target="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH:-tingra}"
    else
        root="$(cd "$(dirname "$0")/.." && pwd)"
        target="${root}/apps/tingra/.build/debug/tingra"
    fi
fi

# `-e`, not `-f`: the target may be a `.app` bundle directory, not just a file.
if [[ ! -e "$target" ]]; then
    echo "sign-app: nothing to sign at '$target' — build it first. Skipping." >&2
    exit 0
fi

# Without an identity there is nothing to sign with; warn (with the fix) but do
# not fail the build — the app still runs, it just keeps re-prompting.
if [[ -z "$IDENTITY" ]]; then
    echo "sign-app: no code-signing identity found in the keychain. Set" >&2
    echo "          TINGRA_SIGN_IDENTITY, or create a Code Signing certificate in" >&2
    echo "          Keychain Access (Certificate Assistant → Create a Certificate)." >&2
    echo "          Skipping signing." >&2
    exit 0
fi

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$target"
echo "sign-app: signed '$target' as $BUNDLE_ID with '$IDENTITY'."
