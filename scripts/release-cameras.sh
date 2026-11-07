#!/bin/bash
#
#  release-cameras.sh
#  tingra-cameras
#
#  Created by Larry Aasen on 2026-11-07.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# One command to cut a Tingra Cameras release from a clean checkout
# (docs/RELEASE.md, "Releasing Tingra Cameras", Decisions C2, C9, and C10).
# It owns the version decision and the publishing; the build, signing,
# verification, notarization, and disk image are scripts/release-app-package.sh,
# which it calls.
#
# What it does, in order:
#   1. Preflight: tools, authentication, branch, clean tree, signing env.
#   2. Choose the version, defaulting to the -dev version with its suffix
#      dropped.
#   3. Bump TINGRA_CAMERAS_VERSION in apps/tingra-cameras/Tingra.xcconfig,
#      commit the bump, and push the branch.
#   4. Package: scripts/release-app-package.sh --app cameras <version>.
#   5. Tag cameras-v<version> and push the tag.
#   6. Create the GitHub release with the disk image, marked not latest, so the
#      repository's latest release stays the engine's (Decision C2).
#   7. Render packaging/homebrew/tingra-cameras.rb into the tap as
#      Casks/tingra-cameras.rb, with this release's version and sha256.
#   8. Optionally reopen the branch on the next -dev version.
#
# Usage:
#   scripts/release-cameras.sh                 # prompt, default = the -dev version, released
#   scripts/release-cameras.sh --version 0.1.0 # skip the prompt
#   scripts/release-cameras.sh --dry-run       # preflight + show the plan, change nothing
#   scripts/release-cameras.sh --no-dev-bump   # skip step 8
#   scripts/release-cameras.sh --yes           # never prompt (this is what CI runs)
#
# --yes answers every confirmation with yes and takes the default version when
# --version is absent, so the release runs unattended, which is how
# .github/workflows/release-cameras.yml drives it. Missing signing credentials
# abort under --yes instead of asking, because an unsigned disk image must
# never reach the tap.
#
# Resumable: if a run stops partway (say notarization times out), run it again
# with the same version. The bump is skipped when it is already in place, a
# tag that already names the current commit is reused, an existing release
# gets its asset replaced, and an unchanged cask is not pushed again. A tag
# that names any other commit is a version that has shipped, and stops the run.
#
# Configuration (env, with defaults):
#   TINGRA_REPO            code + releases repo   (default larryaasen/tingra)
#   TINGRA_TAP_REPO        the Homebrew tap repo  (default larryaasen/homebrew-tingra)
#   TINGRA_RELEASE_BRANCH  the branch releases are cut from (default main)
# plus the signing and notarization environment release-app-package.sh reads
# (TINGRA_SIGN_ID, TINGRA_NOTARY_PROFILE, TINGRA_NOTARY_KEYCHAIN).
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly XCCONFIG="${ROOT}/apps/tingra-cameras/Tingra.xcconfig"
readonly TEMPLATE="${ROOT}/packaging/homebrew/tingra-cameras.rb"
readonly PACKAGE_SCRIPT="${ROOT}/scripts/release-app-package.sh"
readonly DIST="${ROOT}/dist/tingra-cameras"
readonly REPO="${TINGRA_REPO:-larryaasen/tingra}"
readonly TAP_REPO="${TINGRA_TAP_REPO:-larryaasen/homebrew-tingra}"
readonly TAP_CASK="Casks/tingra-cameras.rb"
readonly RELEASE_BRANCH="${TINGRA_RELEASE_BRANCH:-main}"
# The tag prefix that keeps this app's tags apart from the engine's v<x.y.z>.
readonly TAG_PREFIX="cameras-v"

log()  { echo "release-cameras: $*"; }
warn() { echo "release-cameras: WARNING: $*" >&2; }
die()  { echo "release-cameras: ERROR: $*" >&2; exit 1; }

DRY_RUN=false
DEV_BUMP=true
ASSUME_YES=false
REQUESTED_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      [[ $# -ge 2 ]] || die "--version needs a value."; REQUESTED_VERSION="$2"; shift 2 ;;
        --version=*)    REQUESTED_VERSION="${1#*=}"; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --no-dev-bump)  DEV_BUMP=false; shift ;;
        -y|--yes)       ASSUME_YES=true; shift ;;
        -h|--help)      sed -n '10,54p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "unknown argument '$1' (try --help)." ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Reads TINGRA_CAMERAS_VERSION from the app's xcconfig, the one line both of
# the app's version keys read.
current_version() {
    sed -n -E 's/^TINGRA_CAMERAS_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$XCCONFIG"
}

# Writes a version into the xcconfig and reads it back.
write_version() {
    local new="$1" got
    sed -i '' -E "s/^(TINGRA_CAMERAS_VERSION[[:space:]]*=[[:space:]]*).*$/\\1${new}/" "$XCCONFIG"
    got="$(current_version)"
    [[ "$got" == "$new" ]] || die "Tingra.xcconfig did not take the bump (got '${got}')."
}

# Strips a -dev suffix, if any: "0.2.0-dev" -> "0.2.0".
strip_dev() { echo "${1%-dev}"; }

# Increments the patch component: "0.1.0" -> "0.1.1".
next_patch() {
    local base major minor patch
    base="$(strip_dev "$1")"
    IFS='.' read -r major minor patch <<< "$base"
    echo "${major}.${minor}.$((patch + 1))"
}

# Prints the commit a tag names, locally or on the remote, or nothing when the
# tag does not exist. An annotated tag is peeled to its commit.
tag_commit() {
    local commit remote
    commit="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true)"
    if [[ -z "$commit" ]]; then
        remote="$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$1" "refs/tags/$1^{}" 2>/dev/null || true)"
        # A peeled line (^{}) names the commit; a lightweight tag has only one line.
        commit="$(awk '/\^\{\}$/ {print $1; found=1} END {}' <<<"$remote")"
        [[ -n "$commit" ]] || commit="$(awk 'NR==1 {print $1}' <<<"$remote")"
    fi
    echo "$commit"
}

# Asks a yes/no question, defaulting to no. Non-interactive runs must not
# silently take a publishing action, so a missing tty is an error, not a yes,
# unless --yes was passed (the workflow's dispatch button is the confirmation
# then).
confirm() {
    local reply
    if $ASSUME_YES; then
        log "--yes: $1 -> yes"
        return 0
    fi
    [[ -t 0 ]] || die "no terminal for the '$1' prompt — re-run interactively, or pass --yes."
    read -r -p "$1 [y/N]: " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

[[ -f "$XCCONFIG" ]] || die "not found: $XCCONFIG"
[[ -f "$TEMPLATE" ]] || die "cask template not found at $TEMPLATE"
[[ -x "$PACKAGE_SCRIPT" ]] || die "scripts/release-app-package.sh is missing or not executable."

command -v git >/dev/null || die "git is required."
command -v gh  >/dev/null || die "the GitHub CLI (gh) is required — 'brew install gh' then 'gh auth login'."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'."

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "$RELEASE_BRANCH" ]]; then
    warn "on branch '${BRANCH}', not '${RELEASE_BRANCH}'."
    $DRY_RUN || confirm "Release from '${BRANCH}' anyway?" || die "aborted."
fi

# A dirty tree is fatal rather than a prompt: the tag must name a committed
# state, and this script commits a file of its own, which would sweep stray
# edits into the release commit.
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    git -C "$ROOT" status --short >&2
    die "the working tree is dirty — commit or stash the above first."
fi

# The bump commit gets pushed, so a branch behind the remote would be a
# non-fast-forward later, after the tag is already public.
git -C "$ROOT" fetch --quiet origin "$RELEASE_BRANCH" 2>/dev/null || warn "could not fetch origin/${RELEASE_BRANCH}."
if git -C "$ROOT" rev-parse -q --verify "origin/${RELEASE_BRANCH}" >/dev/null; then
    behind="$(git -C "$ROOT" rev-list --count "HEAD..origin/${RELEASE_BRANCH}")"
    [[ "$behind" == "0" ]] || die "${behind} commit(s) behind origin/${RELEASE_BRANCH} — pull first."
fi

# Signing credentials live only in the environment, never a tracked file.
# Without them release-app-package.sh builds an unsigned development image,
# which Gatekeeper rejects on every Mac but the one that built it.
missing_creds=()
for var in TINGRA_SIGN_ID TINGRA_NOTARY_PROFILE; do
    [[ -n "${!var:-}" ]] || missing_creds+=("$var")
done
if [[ ${#missing_creds[@]} -gt 0 ]]; then
    warn "signing/notarization environment not set: ${missing_creds[*]}"
    warn "release-app-package.sh would build an UNSIGNED or un-notarized image — do not publish that."
    if $ASSUME_YES && ! $DRY_RUN; then
        die "refusing to publish unattended without ${missing_creds[*]} — an unsigned image must never reach the tap."
    fi
    $DRY_RUN || confirm "Continue without full signing credentials?" || die "aborted."
fi

# ---------------------------------------------------------------------------
# 2. Choose the version
# ---------------------------------------------------------------------------

CURRENT="$(current_version)"
[[ -n "$CURRENT" ]] || die "could not read TINGRA_CAMERAS_VERSION from ${XCCONFIG}."
HEAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

# The documented scheme: the branch carries the next version with a -dev
# suffix, and releasing drops the suffix. Off-scheme (a bare number), the
# default is that number when it has not shipped (a resumed release), else the
# next patch.
if [[ "$CURRENT" == *-dev ]]; then
    DEFAULT="$(strip_dev "$CURRENT")"
else
    DEFAULT="$CURRENT"
fi
# Never default to a version that shipped from another commit.
while existing="$(tag_commit "${TAG_PREFIX}${DEFAULT}")" && [[ -n "$existing" && "$existing" != "$HEAD_COMMIT" ]]; do
    DEFAULT="$(next_patch "$DEFAULT")"
done

log "current version: ${CURRENT}"

if [[ -n "$REQUESTED_VERSION" ]]; then
    VERSION="$REQUESTED_VERSION"
elif $DRY_RUN || $ASSUME_YES; then
    VERSION="$DEFAULT"
else
    [[ -t 0 ]] || die "no terminal for the version prompt — pass --version <x.y.z>."
    read -r -p "Next version [${DEFAULT}]: " reply
    VERSION="${reply:-$DEFAULT}"
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version '${VERSION}' must be MAJOR.MINOR.PATCH with no suffix (a release never carries -dev)."
readonly TAG="${TAG_PREFIX}${VERSION}"
readonly IMAGE="${DIST}/Tingra-Cameras-${VERSION}-arm64.dmg"

# A tag naming this commit is a resumed release; a tag naming any other is a
# version that has shipped. The bump commit is HEAD on a resumed run, because
# the bump below is skipped when the version is already in place.
TAG_COMMIT="$(tag_commit "$TAG")"
RESUMING=false
if [[ -n "$TAG_COMMIT" ]]; then
    [[ "$TAG_COMMIT" == "$HEAD_COMMIT" && "$CURRENT" == "$VERSION" ]] \
        || die "tag ${TAG} already exists on another commit — pick a version that has not shipped."
    RESUMING=true
fi

echo
log "plan:"
echo "  version:   ${CURRENT}  ->  ${VERSION}"
echo "  tag:       ${TAG}  (pushed to ${REPO})$($RESUMING && echo ", already at HEAD: resuming")"
echo "  branch:    ${BRANCH}  (bump commit pushed)"
echo "  release:   ${TAG}, not marked latest"
echo "  tap:       ${TAP_REPO}, ${TAP_CASK}"
echo "  artifact:  dist/tingra-cameras/$(basename "$IMAGE")"
echo

if $DRY_RUN; then
    log "dry run — nothing was changed."
    exit 0
fi

confirm "Cut and publish Tingra Cameras ${VERSION}?" || die "aborted."

# ---------------------------------------------------------------------------
# 3. Bump, commit, push
# ---------------------------------------------------------------------------

# Skipped when already in place, so a re-run after a mid-release failure
# resumes instead of double-bumping.
if [[ "$CURRENT" == "$VERSION" ]]; then
    log "version already at ${VERSION} — skipping the bump."
else
    log "bumping to ${VERSION}"
    write_version "$VERSION"
    git -C "$ROOT" add "$XCCONFIG"
    git -C "$ROOT" commit -q -m "Tingra Cameras ${VERSION}"
    log "committed the version bump."
fi

git -C "$ROOT" push -q origin "$BRANCH"
log "pushed ${BRANCH}."

# ---------------------------------------------------------------------------
# 4. Package: archive, export, verify, run, notarize, staple, disk image
# ---------------------------------------------------------------------------

"$PACKAGE_SCRIPT" --app cameras "$VERSION"
[[ -f "$IMAGE" ]] || die "expected artifact not found: $IMAGE"
SHA="$(shasum -a 256 "$IMAGE" | awk '{print $1}')"

# ---------------------------------------------------------------------------
# 5. Tag and push the tag
# ---------------------------------------------------------------------------

if git -C "$ROOT" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    log "tag ${TAG} already exists locally — reusing it."
else
    git -C "$ROOT" tag "$TAG"
fi
git -C "$ROOT" push -q origin "refs/tags/${TAG}"
log "pushed ${TAG}."

# ---------------------------------------------------------------------------
# 6. The GitHub release
# ---------------------------------------------------------------------------

# --latest=false keeps the repository's latest release the engine's, which is
# what its README and the CLI's install instructions point at (Decision C2).
readonly INSTALL_COMMAND="brew install --cask ${TAP_REPO%/*}/${TAP_REPO#*homebrew-}/tingra-cameras"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    log "release ${TAG} exists — uploading the image (clobbering)."
    gh release upload "$TAG" "$IMAGE" --repo "$REPO" --clobber
else
    gh release create "$TAG" "$IMAGE" --repo "$REPO" --latest=false \
        --title "Tingra Cameras ${VERSION}" \
        --notes "Tingra Cameras ${VERSION} — Apple Silicon (arm64), macOS 26 or later, signed and notarized. \
Install: \`${INSTALL_COMMAND}\`, or open the disk image and drag the app to Applications."
fi

# ---------------------------------------------------------------------------
# 7. The tap: render the cask with this release's version and sha256
# ---------------------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$TAP_REPO" "$WORK" -- --depth 1 >/dev/null 2>&1 \
    || die "could not clone the tap ${TAP_REPO} — check that it exists and that you have push access."
mkdir -p "$WORK/$(dirname "$TAP_CASK")"
# The template's url interpolates #{version}, so only version and sha256
# change. Each is the cask's first line of its kind, at two spaces' indent.
sed -E \
    -e "s/^  version \"[^\"]*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 \"[^\"]*\"/  sha256 \"${SHA}\"/" \
    "$TEMPLATE" > "$WORK/$TAP_CASK"
grep -q "^  version \"${VERSION}\"$" "$WORK/$TAP_CASK" || die "the rendered cask does not carry version ${VERSION}."
grep -q "^  sha256 \"${SHA}\"$" "$WORK/$TAP_CASK" || die "the rendered cask does not carry the image's sha256."

if [[ -z "$(git -C "$WORK" status --porcelain)" ]]; then
    log "tap cask already at ${VERSION}/${SHA} — nothing to push."
else
    # The tap clone is a fresh temp directory with no identity of its own, so
    # borrow this repo's. A bare runner has none configured, and git would fail
    # with "empty ident name" after the tag and release are already public.
    TAP_AUTHOR_NAME="$(git -C "$ROOT" config user.name || true)"
    TAP_AUTHOR_EMAIL="$(git -C "$ROOT" config user.email || true)"
    [[ -n "$TAP_AUTHOR_NAME" && -n "$TAP_AUTHOR_EMAIL" ]] \
        || die "git user.name/user.email are unset, so the tap commit has no author — set them with \
'git config --global user.name …' and 'git config --global user.email …', then re-run \
(this script resumes). The release workflow sets them in its 'Configure git and gh' step."
    git -C "$WORK" add "$TAP_CASK"
    git -C "$WORK" -c user.name="$TAP_AUTHOR_NAME" -c user.email="$TAP_AUTHOR_EMAIL" \
        commit -q -m "tingra-cameras ${VERSION}"
    git -C "$WORK" push -q
    log "pushed tingra-cameras ${VERSION} to ${TAP_REPO}."
fi

# ---------------------------------------------------------------------------
# 8. Reopen the branch on the next -dev version
# ---------------------------------------------------------------------------

if $DEV_BUMP; then
    DEV_VERSION="$(next_patch "$VERSION")-dev"
    echo
    if confirm "Reopen ${BRANCH} on ${DEV_VERSION}?"; then
        write_version "$DEV_VERSION"
        git -C "$ROOT" add "$XCCONFIG"
        git -C "$ROOT" commit -q -m "Bumped Tingra Cameras to ${DEV_VERSION}."
        git -C "$ROOT" push -q origin "$BRANCH"
        log "${BRANCH} now on ${DEV_VERSION}."
    fi
fi

echo
log "released Tingra Cameras ${VERSION} (${TAG})."
echo "  install:  ${INSTALL_COMMAND}"
echo "  upgrade:  brew update && brew upgrade --cask tingra-cameras"
