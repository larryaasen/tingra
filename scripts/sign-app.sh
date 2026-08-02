#!/bin/bash
#
#  sign-app.sh
#  tingra
#
#  Created by Larry Aasen on 2026-07-06.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# Re-signs the built `Tingra.app` with a stable code-signing identity so macOS
# TCC permission grants (Screen Recording, Camera, Microphone) persist across
# rebuilds.
#
# Why this survived the move to an Xcode app target: the target's automatic
# signing (CODE_SIGN_STYLE = Automatic with DEVELOPMENT_TEAM set) already
# produces a certificate-based designated requirement, which is what makes a
# grant stick — so on a configured machine this script is belt-and-braces. It
# still earns its place where automatic signing produces no usable signature:
# a build made with CODE_SIGNING_ALLOWED=NO (how CI builds), or a checkout on a
# Mac whose keychain has no certificate for the project's team. Without a
# certificate the bundle is ad-hoc signed, and an ad-hoc signature's designated
# requirement is the binary's cdhash — which changes on every build, so TCC
# treats each rebuild as a brand-new app and re-prompts even though the
# previous build's toggle still shows ON.
#
# Entitlements are preserved from the bundle being signed (Xcode applies
# tingra-app/tingra-app.entitlements at build time): the hardened runtime
# denies camera and microphone access without them.
#
# This is a DEVELOPER-CONVENIENCE step only. The shipping build is Developer ID
# signed (hardened runtime) and notarized per CLI.md "Distribution"; this script
# is not that pipeline.
#
# Usage:
#   - Automatically, from `scripts/run-app.sh`, which passes the built bundle.
#   - With an explicit `.app` bundle as the first argument:
#     `scripts/sign-app.sh path/to/Tingra.app`.
#   - With no argument, it signs the bundle `run-app.sh` builds.
#
# Override the signing identity with TINGRA_SIGN_IDENTITY; otherwise the first
# available code-signing identity in the keychain is used.
set -euo pipefail

# The stable bundle identifier the grant is keyed to — matches the app target's
# PRODUCT_BUNDLE_IDENTIFIER. Kept constant so the designated requirement never
# drifts.
readonly BUNDLE_ID="com.moonwink.tingra.app"

# Resolve the signing identity: an explicit override, else the first
# code-signing certificate in the keychain (typically an "Apple Development:
# <your name>" certificate). Nothing identifying is hard-coded — the developer's
# certificate and team stay in the keychain and in the git-ignored
# apps/tingra-app/Local.xcconfig, never in a tracked file.
IDENTITY="${TINGRA_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | grep -o '"[^"]*"' | head -n1 | tr -d '"')"
fi

# Locate the bundle to sign. An explicit first argument wins (run-app.sh passes
# the bundle path); otherwise fall back to the product run-app.sh builds, so the
# script also works standalone after a run-app.sh build.
target="${1:-}"
if [[ -z "$target" ]]; then
    root="$(cd "$(dirname "$0")/.." && pwd)"
    target="${root}/apps/tingra-app/.build/DerivedData/Build/Products/Debug/Tingra.app"
fi

# `-e`, not `-f`: the target is a `.app` bundle directory, not a file.
if [[ ! -e "$target" ]]; then
    echo "sign-app: nothing to sign at '$target' — build it first with" >&2
    echo "          scripts/run-app.sh. Skipping." >&2
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

# --preserve-metadata=entitlements keeps the hardened runtime's camera and
# audio-input entitlements the build applied; re-signing without them would
# leave the app unable to open a camera or microphone.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
    --options runtime --preserve-metadata=entitlements "$target"
echo "sign-app: signed '$target' as $BUNDLE_ID with '$IDENTITY'."
