#!/bin/bash
#
#  release-publish.sh
#  tingra
#
#  Created by Larry Aasen on 2026-07-11.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# One command to cut and deploy a Tingra release end to end, tingra-cli and
# Tingra.app at one version (docs/RELEASE.md, Decision 6):
#   1. build + sign + notarize + package the CLI (scripts/release-cli-package.sh),
#   2. the same for the app, into a disk image (scripts/release-app-package.sh),
#   3. tag the commit and push the tag,
#   4. create the GitHub release and upload the artifacts, and
#   5. render packaging/homebrew/tingra-cli.rb and packaging/homebrew/tingra.rb
#      into the tap repo with this release's version and sha256s, and push them.
#
# After this runs, `brew install larryaasen/tingra/tingra-cli` and
# `brew install --cask larryaasen/tingra/tingra` get the new version. Requires
# the GitHub CLI (`gh`) authenticated with push access to both repos, plus the
# signing and notarization environment the packaging scripts need
# (TINGRA_SIGN_ID, TINGRA_INSTALLER_SIGN_ID, TINGRA_NOTARY_PROFILE, and the
# app's TINGRA_APP_PROFILE). Both are packaged before anything is tagged, so a
# failure in either publishes nothing.
#
# Usage:
#   scripts/release-publish.sh [version]
# The version defaults to TingraCLIVersion.current in Version.swift, so a
# normal release is just `scripts/release-publish.sh` once that constant is bumped.
#
# Configuration (env, with defaults):
#   TINGRA_REPO        code + releases repo   (default larryaasen/tingra)
#   TINGRA_TAP_REPO    the Homebrew tap repo  (default larryaasen/homebrew-tingra)
#   TINGRA_TAP_FORMULA formula path in the tap (default Formula/tingra-cli.rb)
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly CLI_DIR="${ROOT}/apps/tingra-cli"
readonly TEMPLATE="${ROOT}/packaging/homebrew/tingra-cli.rb"
readonly CASK_TEMPLATE="${ROOT}/packaging/homebrew/tingra.rb"
readonly DIST="${ROOT}/dist"
readonly REPO="${TINGRA_REPO:-larryaasen/tingra}"
readonly TAP_REPO="${TINGRA_TAP_REPO:-larryaasen/homebrew-tingra}"
readonly TAP_FORMULA="${TINGRA_TAP_FORMULA:-Formula/tingra-cli.rb}"
readonly TAP_CASK="Casks/tingra.rb"

log()  { echo "release-publish: $*"; }
die()  { echo "release-publish: ERROR: $*" >&2; exit 1; }

# 0. Preconditions: the tools and a clean tree (a tag must name a real commit).
command -v gh >/dev/null || die "the GitHub CLI (gh) is required — install with 'brew install gh' and 'gh auth login'."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'."
[[ -f "$TEMPLATE" ]] || die "formula template not found at $TEMPLATE"
[[ -f "$CASK_TEMPLATE" ]] || die "cask template not found at $CASK_TEMPLATE"
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

# 2. Build, sign, notarize, and package the CLI. release-cli-package.sh asserts
#    the version matches the embedded Info.plist, so a mismatch stops here. It
#    empties dist/ first, so it runs before the app's packaging, which writes
#    only dist/tingra-app/.
"${ROOT}/scripts/release-cli-package.sh" "$VERSION"
ZIP="${DIST}/tingra-cli-${VERSION}-arm64.zip"
PKG="${DIST}/tingra-cli-${VERSION}.pkg"
[[ -f "$ZIP" ]] || die "expected artifact not found: $ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# 3. The same for the app, into a disk image. release-app-package.sh asserts
#    the app carries exactly this version, which release.sh bumped with the CLI's.
"${ROOT}/scripts/release-app-package.sh" --app tingra "$VERSION"
IMAGE="${DIST}/tingra-app/Tingra-${VERSION}-arm64.dmg"
[[ -f "$IMAGE" ]] || die "expected artifact not found: $IMAGE"
IMAGE_SHA="$(shasum -a 256 "$IMAGE" | awk '{print $1}')"

# 4. Tag the current commit and push it (idempotent: reuse an existing tag).
if git -C "$ROOT" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    log "tag ${TAG} already exists locally — reusing it."
else
    git -C "$ROOT" tag "$TAG"
fi
git -C "$ROOT" push origin "$TAG"

# 5. Create the GitHub release (or reuse it) and upload the artifacts. The zip
#    and the disk image are required; the pkg is attached only if
#    release-cli-package.sh produced one.
assets=("$ZIP" "$IMAGE")
[[ -f "$PKG" ]] && assets+=("$PKG")
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "release ${TAG} exists — uploading artifacts (clobbering)."
    gh release upload "$TAG" "${assets[@]}" --repo "$REPO" --clobber
else
    gh release create "$TAG" "${assets[@]}" --repo "$REPO" \
        --title "Tingra ${VERSION}" \
        --notes "Tingra ${VERSION}: Tingra.app and tingra-cli, Apple Silicon (arm64), macOS 15 or later, signed and \
notarized. Install the app with \`brew install --cask ${TAP_REPO%/*}/${TAP_REPO#*homebrew-}/tingra\`, or open the disk \
image and drag it to Applications. Install the CLI with \`brew install ${TAP_REPO%/*}/${TAP_REPO#*homebrew-}/tingra-cli\`."
fi

# 6. Update the tap: render the formula and cask templates with this release's
#    version and sha256s and push them in one commit. Each template's url uses
#    #{version}, so only version and sha256 change. In the cask each is the
#    first line of its kind, at two spaces' indent.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP_REPO" "$WORK" -- --depth 1 >/dev/null 2>&1 \
    || die "could not clone the tap ${TAP_REPO} — create it (empty) and ensure you have push access."
mkdir -p "$WORK/$(dirname "$TAP_FORMULA")"
sed -E \
    -e "s/version \"[^\"]*\"/version \"${VERSION}\"/" \
    -e "s/sha256 \"[^\"]*\"/sha256 \"${SHA}\"/" \
    "$TEMPLATE" > "$WORK/$TAP_FORMULA"
mkdir -p "$WORK/$(dirname "$TAP_CASK")"
sed -E \
    -e "s/^  version \"[^\"]*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 \"[^\"]*\"/  sha256 \"${IMAGE_SHA}\"/" \
    "$CASK_TEMPLATE" > "$WORK/$TAP_CASK"
grep -q "^  version \"${VERSION}\"$" "$WORK/$TAP_CASK" || die "the rendered cask does not carry version ${VERSION}."
grep -q "^  sha256 \"${IMAGE_SHA}\"$" "$WORK/$TAP_CASK" || die "the rendered cask does not carry the image's sha256."

if [[ -z "$(git -C "$WORK" status --porcelain)" ]]; then
    log "tap formula and cask already at ${VERSION} — nothing to push."
else
    # The tap clone is a fresh temp directory with no identity of its own, so
    # borrow this repo's. A bare runner has none configured, and git would fail
    # here with "empty ident name" after the tag and release are already
    # public — name the fix instead.
    TAP_AUTHOR_NAME="$(git -C "$ROOT" config user.name || true)"
    TAP_AUTHOR_EMAIL="$(git -C "$ROOT" config user.email || true)"
    [[ -n "$TAP_AUTHOR_NAME" && -n "$TAP_AUTHOR_EMAIL" ]] \
        || die "git user.name/user.email are unset, so the tap commit has no author — set them with \
'git config --global user.name …' and 'git config --global user.email …', then re-run \
(this script is idempotent). The release workflow sets them in its 'Configure git and gh' step."

    git -C "$WORK" add "$TAP_FORMULA" "$TAP_CASK"
    git -C "$WORK" -c user.name="$TAP_AUTHOR_NAME" \
        -c user.email="$TAP_AUTHOR_EMAIL" \
        commit -q -m "Tingra ${VERSION}"
    git -C "$WORK" push -q
    log "pushed the tingra-cli formula and the tingra cask at ${VERSION} to ${TAP_REPO}."
fi

echo
log "released ${TAG}."
echo "  install:  brew install --cask ${TAP_REPO%/*}/${TAP_REPO#*homebrew-}/tingra"
echo "            brew install ${TAP_REPO%/*}/${TAP_REPO#*homebrew-}/tingra-cli"
echo "  upgrade:  brew update && brew upgrade --cask tingra && brew upgrade tingra-cli"