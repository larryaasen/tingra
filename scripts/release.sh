#!/bin/bash
#
#  release.sh
#  tingra-cli
#
#  Created by Larry Aasen on 2026-07-11.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# One command to cut and deploy a tingra-cli Homebrew release end to end:
#   1. build + sign + notarize + package  (scripts/package-cli.sh),
#   2. tag the commit and push the tag,
#   3. create the GitHub release and upload the artifacts, and
#   4. render packaging/homebrew/tingra-cli.rb into the tap repo with this
#      release's version + sha256, and push it.
#
# After this runs, `brew install larryaasen/tingra/tingra-cli` gets the new
# version. Requires the GitHub CLI (`gh`) authenticated with push access to
# both repos, plus the signing/notarization environment package-cli.sh needs
# (TINGRA_SIGN_ID, TINGRA_INSTALLER_SIGN_ID, TINGRA_NOTARY_PROFILE).
#
# Usage:
#   scripts/release.sh [version]
# The version defaults to TingraCLIVersion.current in Version.swift, so a
# normal release is just `scripts/release.sh` once that constant is bumped.
#
# Configuration (env, with defaults):
#   TINGRA_REPO        code + releases repo   (default larryaasen/tingra)
#   TINGRA_TAP_REPO    the Homebrew tap repo  (default larryaasen/homebrew-tingra)
#   TINGRA_TAP_FORMULA formula path in the tap (default Formula/tingra-cli.rb)
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly CLI_DIR="${ROOT}/apps/tingra-cli"
readonly TEMPLATE="${ROOT}/packaging/homebrew/tingra-cli.rb"
readonly DIST="${ROOT}/dist"
readonly REPO="${TINGRA_REPO:-larryaasen/tingra}"
readonly TAP_REPO="${TINGRA_TAP_REPO:-larryaasen/homebrew-tingra}"
readonly TAP_FORMULA="${TINGRA_TAP_FORMULA:-Formula/tingra-cli.rb}"

log()  { echo "release: $*"; }
die()  { echo "release: ERROR: $*" >&2; exit 1; }

# 0. Preconditions: the tools and a clean tree (a tag must name a real commit).
command -v gh >/dev/null || die "the GitHub CLI (gh) is required — install with 'brew install gh' and 'gh auth login'."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'."
[[ -f "$TEMPLATE" ]] || die "formula template not found at $TEMPLATE"
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    die "the working tree is dirty — commit or stash first so the tag names a clean commit."
fi

# 1. Resolve the version: the argument, else the source-of-truth constant.
if [[ -n "${1:-}" ]]; then
    VERSION="$1"
else
    VERSION="$(grep -Eo 'static let current = "[^"]+"' "${CLI_DIR}/Sources/TingraCLI/Version.swift" \
        | sed -E 's/.*"([^"]+)".*/\1/')"
fi
[[ -n "$VERSION" ]] || die "could not determine the version"
[[ "$VERSION" != *-dev ]] || die "version is '$VERSION' — bump Version.swift off -dev before releasing."
readonly TAG="v${VERSION}"
log "releasing ${TAG} → ${REPO} (tap ${TAP_REPO})"

# 2. Build, sign, notarize, and package. package-cli.sh asserts the version
#    matches the embedded Info.plist, so a mismatch stops here.
"${ROOT}/scripts/package-cli.sh" "$VERSION"
ZIP="${DIST}/tingra-cli-${VERSION}-arm64.zip"
PKG="${DIST}/tingra-cli-${VERSION}.pkg"
[[ -f "$ZIP" ]] || die "expected artifact not found: $ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# 3. Tag the current commit and push it (idempotent: reuse an existing tag).
if git -C "$ROOT" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    log "tag ${TAG} already exists locally — reusing it."
else
    git -C "$ROOT" tag "$TAG"
fi
git -C "$ROOT" push origin "$TAG"

# 4. Create the GitHub release (or reuse it) and upload the artifacts. The zip
#    is required; the pkg is attached only if package-cli.sh produced one.
assets=("$ZIP")
[[ -f "$PKG" ]] && assets+=("$PKG")
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "release ${TAG} exists — uploading artifacts (clobbering)."
    gh release upload "$TAG" "${assets[@]}" --repo "$REPO" --clobber
else
    gh release create "$TAG" "${assets[@]}" --repo "$REPO" \
        --title "tingra-cli ${VERSION}" \
        --notes "tingra-cli ${VERSION} — Apple Silicon (arm64), signed and notarized. Install: \`brew install ${TAP_REPO%/*}/${TAP_REPO#*homebrew-}/tingra-cli\`"
fi

# 5. Update the tap: render the formula template with this release's version +
#    sha256 and push it. The template's url uses #{version}, so only version and
#    sha256 change.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP_REPO" "$WORK" -- --depth 1 >/dev/null 2>&1 \
    || die "could not clone the tap ${TAP_REPO} — create it (empty) and ensure you have push access."
mkdir -p "$WORK/$(dirname "$TAP_FORMULA")"
sed -E \
    -e "s/version \"[^\"]*\"/version \"${VERSION}\"/" \
    -e "s/sha256 \"[^\"]*\"/sha256 \"${SHA}\"/" \
    "$TEMPLATE" > "$WORK/$TAP_FORMULA"

if [[ -z "$(git -C "$WORK" status --porcelain)" ]]; then
    log "tap formula already at ${VERSION}/${SHA} — nothing to push."
else
    git -C "$WORK" add "$TAP_FORMULA"
    git -C "$WORK" -c user.name="$(git -C "$ROOT" config user.name)" \
        -c user.email="$(git -C "$ROOT" config user.email)" \
        commit -q -m "tingra-cli ${VERSION}"
    git -C "$WORK" push -q
    log "pushed tingra-cli ${VERSION} to ${TAP_REPO}."
fi

echo
log "released ${TAG}."
echo "  install:  brew install ${TAP_REPO%/*}/${TAP_REPO#*homebrew-}/tingra-cli"
echo "  upgrade:  brew update && brew upgrade tingra-cli"