#!/bin/bash
#
#  package-cli.sh
#  tingra-cli
#
#  Created by Larry Aasen on 2026-07-09.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# Builds, signs, notarizes, and packages `tingra-cli` for distribution through
# the Homebrew tap (see docs/CLI.md, "Distribution"). Apple Silicon (arm64)
# only. Produces two artifacts from one signed binary:
#   - a zip the tap downloads (a bare Mach-O can't be stapled; Gatekeeper
#     fetches the notarization ticket online on first run), and
#   - a stapled .pkg for offline-capable direct download.
#
# The signing identity stays stable across releases so TCC grants (Camera,
# Microphone) survive updates: identifier com.moonwink.tingra.cli, hardened
# runtime, the entitlements in apps/tingra-cli/tingra-cli.entitlements.
#
# Environment (signing/notarization are skipped, with a warning, when unset —
# so a local run still builds, packages, and prints the sha256):
#   TINGRA_SIGN_ID            "Developer ID Application: … (TEAMID)"
#   TINGRA_INSTALLER_SIGN_ID  "Developer ID Installer: … (TEAMID)"   (for the .pkg)
#   TINGRA_NOTARY_PROFILE     notarytool keychain profile name (`notarytool store-credentials`)
#
# Usage:
#   scripts/package-cli.sh [version]
# The version defaults to what `tingra-cli version` reports; the script asserts
# it matches the embedded Info.plist so a release can't ship mislabelled.
set -euo pipefail

readonly BUNDLE_ID="com.moonwink.tingra.cli"
readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly CLI_DIR="${ROOT}/apps/tingra-cli"
readonly ENTITLEMENTS="${CLI_DIR}/tingra-cli.entitlements"
readonly DIST="${ROOT}/dist"

log()  { echo "package-cli: $*"; }
warn() { echo "package-cli: WARNING: $*" >&2; }
die()  { echo "package-cli: ERROR: $*" >&2; exit 1; }

# 1. Build the release binary (arm64 only, per Platform Support).
log "building release binary…"
( cd "$CLI_DIR" && swift build -c release --arch arm64 )
BIN="$(cd "$CLI_DIR" && swift build -c release --arch arm64 --show-bin-path)/tingra-cli"
[[ -f "$BIN" ]] || die "built binary not found at $BIN"

# 2. Resolve and reconcile the version (arg → `version` subcommand), and assert
#    the embedded Info.plist agrees so the tag, binary, and plist never drift.
VERSION="${1:-$("$BIN" version | awk '{print $2}')}"
[[ -n "$VERSION" ]] || die "could not determine the version"
if ! otool -s __TEXT __info_plist "$BIN" >/dev/null 2>&1; then
    die "the binary has no embedded __TEXT,__info_plist section (see Package.swift linker flags)"
fi
# The embedded section's bytes are the verbatim Info.plist; confirm the version
# string is present in the source plist that was embedded.
if ! grep -q "<string>${VERSION}</string>" "${CLI_DIR}/Info.plist"; then
    die "Info.plist CFBundleShortVersionString does not match version ${VERSION}; update both together"
fi
log "packaging tingra-cli ${VERSION} (arm64)"

# 3. Stage a clean copy to sign and package.
rm -rf "$DIST"
mkdir -p "$DIST"
STAGE_BIN="${DIST}/tingra-cli"
cp "$BIN" "$STAGE_BIN"

# 4. Sign (Developer ID Application, hardened runtime, stable identifier), then
#    verify identity, entitlements, and the embedded plist — the same checks CI
#    asserts so a regression fails the pipeline, not a user's Mac.
if [[ -n "${TINGRA_SIGN_ID:-}" ]]; then
    log "signing with '${TINGRA_SIGN_ID}'…"
    codesign --force --options runtime --timestamp \
        --sign "$TINGRA_SIGN_ID" \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$STAGE_BIN"
    codesign --verify --strict --verbose=2 "$STAGE_BIN"
    codesign -d --entitlements - "$STAGE_BIN" >/dev/null
    otool -s __TEXT __info_plist "$STAGE_BIN" >/dev/null
    log "signature, entitlements, and embedded plist verified."
else
    warn "TINGRA_SIGN_ID unset — skipping signing (the artifact will NOT be notarizable)."
fi

# 5. Zip for the tap.
ZIP="${DIST}/tingra-cli-${VERSION}-arm64.zip"
( cd "$DIST" && ditto -c -k --keepParent "tingra-cli" "$ZIP" )
log "wrote $ZIP"

# 6. Notarize the zip (online ticket; a bare binary can't be stapled).
if [[ -n "${TINGRA_NOTARY_PROFILE:-}" && -n "${TINGRA_SIGN_ID:-}" ]]; then
    log "notarizing the zip…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$TINGRA_NOTARY_PROFILE" --wait
    log "zip notarized (Gatekeeper fetches the ticket online on first run)."
else
    warn "TINGRA_NOTARY_PROFILE unset — skipping notarization of the zip."
fi

# 7. Emit the sha256 the Homebrew formula pins. The zip is the tap's only
#    input, so surface it now — before the optional .pkg — so a pkg or keychain
#    hiccup below can never swallow the one value the release actually needs.
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
log "zip sha256: $SHA   (paste into packaging/homebrew/tingra-cli.rb)"

# 8. Build the offline .pkg: install to /usr/local/bin (Homebrew's own path is
#    managed by the formula; the pkg is the manual-install fallback). Best
#    effort — the notarized zip above is what the tap uses, so a pkg
#    signing/keychain failure warns rather than aborting the release.
PKG="${DIST}/tingra-cli-${VERSION}.pkg"
build_pkg() {
    local pkg_root="${DIST}/pkgroot"
    local component="${DIST}/tingra-cli-component.pkg"
    mkdir -p "${pkg_root}/usr/local/bin" || return 1
    cp "$STAGE_BIN" "${pkg_root}/usr/local/bin/tingra-cli" || return 1
    pkgbuild --root "$pkg_root" --identifier "$BUNDLE_ID" --version "$VERSION" \
        --install-location "/" "$component" || return 1
    if [[ -n "${TINGRA_INSTALLER_SIGN_ID:-}" ]]; then
        productbuild --package "$component" --sign "$TINGRA_INSTALLER_SIGN_ID" "$PKG" || return 1
        if [[ -n "${TINGRA_NOTARY_PROFILE:-}" ]]; then
            log "notarizing and stapling the pkg…"
            xcrun notarytool submit "$PKG" --keychain-profile "$TINGRA_NOTARY_PROFILE" --wait || return 1
            xcrun stapler staple "$PKG" || return 1
        else
            warn "TINGRA_NOTARY_PROFILE unset — pkg signed but not notarized/stapled."
        fi
    else
        productbuild --package "$component" "$PKG" || return 1
        warn "TINGRA_INSTALLER_SIGN_ID unset — pkg is unsigned (dev use only)."
    fi
    rm -f "$component"
}
if build_pkg; then
    log "wrote $PKG"
else
    warn "the .pkg step did not complete (see the error above). The notarized zip is the"
    warn "Homebrew artifact, so the release is NOT blocked. A -60008 authorization error is"
    warn "usually the keychain: unlock it and run 'security set-key-partition-list -S"
    warn "apple-tool:,apple: -k <login-password> ~/Library/Keychains/login.keychain-db', then"
    warn "re-run productbuild on dist/tingra-cli-component.pkg."
    PKG=""
fi

# 9. Final summary.
echo
log "artifacts in ${DIST}:"
echo "  zip:    $ZIP"
[[ -n "$PKG" ]] && echo "  pkg:    $PKG"
echo "  sha256: $SHA"
