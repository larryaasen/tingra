#!/bin/bash
#
#  release-cli.sh
#  tingra-cli
#
#  Created by Larry Aasen on 2026-08-15.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# One interactive command to cut a tingra-cli release from a clean checkout.
# This is the front end over scripts/release-cli-publish.sh: it owns the *version
# decision* — the step packaging/README.md previously left to the operator —
# and delegates the actual build/sign/notarize/tag/publish/tap work to
# release-cli-publish.sh, which stays non-interactive so CI can keep calling it directly.
#
# What it does, in order:
#   1. Preflight: tools, authentication, branch, clean tree, signing env.
#   2. Prompt for the version, defaulting to the next increment.
#   3. Bump TingraCLIVersion.current and Info.plist's version keys together.
#   4. Commit the bump and push the branch.
#   5. Run scripts/release-cli-publish.sh, which tags, packages, publishes, updates the tap.
#   6. Optionally reopen main on the next -dev version (the documented scheme).
#
# Usage:
#   scripts/release-cli.sh                 # prompt, default = next patch
#   scripts/release-cli.sh --version 0.2.0 # skip the prompt
#   scripts/release-cli.sh --dry-run       # preflight + show the plan, change nothing
#   scripts/release-cli.sh --no-dev-bump   # skip step 6
#
# Resumable: if a run stops after the bump (say notarization times out), just
# run it again with the same version — the bump and commit are skipped when
# they are already in place, and release-cli-publish.sh is itself idempotent.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly CLI_DIR="${ROOT}/apps/tingra-cli"
readonly VERSION_SWIFT="${CLI_DIR}/Sources/TingraCLI/Version.swift"
readonly INFO_PLIST="${CLI_DIR}/Info.plist"
readonly RELEASE_BRANCH="${TINGRA_RELEASE_BRANCH:-main}"

log()  { echo "release-cli: $*"; }
warn() { echo "release-cli: WARNING: $*" >&2; }
die()  { echo "release-cli: ERROR: $*" >&2; exit 1; }

DRY_RUN=false
DEV_BUMP=true
REQUESTED_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      REQUESTED_VERSION="${2:-}"; shift 2 ;;
        --version=*)    REQUESTED_VERSION="${1#*=}"; shift ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --no-dev-bump)  DEV_BUMP=false; shift ;;
        -h|--help)      sed -n '10,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "unknown argument '$1' (try --help)." ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Reads TingraCLIVersion.current, the source of truth for the product version.
current_version() {
    grep -Eo 'static let current = "[^"]+"' "$VERSION_SWIFT" \
        | sed -E 's/.*"([^"]+)".*/\1/'
}

# Reads CFBundleShortVersionString from the embedded Info.plist. Used to prove
# the two stayed in sync, which release-cli-package.sh asserts again at package time.
plist_version() {
    sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$INFO_PLIST"
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

# True when a release tag exists locally or on the remote.
tag_exists() {
    git -C "$ROOT" rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1 && return 0
    [[ -n "$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$1" 2>/dev/null)" ]]
}

# Asks a yes/no question, defaulting to no. Non-interactive runs must not
# silently take a publishing action, so a missing tty is an error, not a yes.
confirm() {
    local reply
    [[ -t 0 ]] || die "no terminal for the '$1' prompt — re-run interactively."
    read -r -p "$1 [y/N]: " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# Writes a version into both Version.swift and the embedded Info.plist, then
# reads them back. They are bumped together on purpose: release-cli-package.sh refuses
# to package a binary whose plist and constant disagree.
write_version() {
    local new="$1"
    sed -i '' -E "s/(static let current = \")[^\"]*(\")/\1${new}\2/" "$VERSION_SWIFT"
    sed -i '' \
        -e "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>${new}</string>|;}" \
        -e "/<key>CFBundleVersion<\/key>/{n;s|<string>.*</string>|<string>${new}</string>|;}" \
        "$INFO_PLIST"

    local got_swift got_plist
    got_swift="$(current_version)"
    got_plist="$(plist_version)"
    [[ "$got_swift" == "$new" ]] || die "Version.swift did not take the bump (got '${got_swift}')."
    [[ "$got_plist" == "$new" ]] || die "Info.plist did not take the bump (got '${got_plist}')."
}

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

[[ -f "$VERSION_SWIFT" ]] || die "not found: $VERSION_SWIFT"
[[ -f "$INFO_PLIST" ]]    || die "not found: $INFO_PLIST"
[[ -x "${ROOT}/scripts/release-cli-publish.sh" ]] || die "scripts/release-cli-publish.sh is missing or not executable."

command -v git >/dev/null || die "git is required."
command -v gh  >/dev/null || die "the GitHub CLI (gh) is required — 'brew install gh' then 'gh auth login'."
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'."

BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "$RELEASE_BRANCH" ]]; then
    warn "on branch '${BRANCH}', not '${RELEASE_BRANCH}'."
    $DRY_RUN || confirm "Release from '${BRANCH}' anyway?" || die "aborted."
fi

# A dirty tree is fatal rather than a prompt: release-cli-publish.sh requires a clean tree
# so the tag names a committed state, and this script is about to write two
# files of its own — stray edits would be swept into the release commit.
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

# Signing credentials live only in the environment (never a tracked file).
# Without them release-cli-package.sh falls back to an unsigned artifact, which must
# never reach the tap: Gatekeeper would reject it and TCC grants key to nothing.
missing_creds=()
for var in TINGRA_SIGN_ID TINGRA_INSTALLER_SIGN_ID TINGRA_NOTARY_PROFILE; do
    [[ -n "${!var:-}" ]] || missing_creds+=("$var")
done
if [[ ${#missing_creds[@]} -gt 0 ]]; then
    warn "signing/notarization environment not set: ${missing_creds[*]}"
    warn "release-cli-package.sh would fall back to an UNSIGNED artifact — do not publish that."
    $DRY_RUN || confirm "Continue without full signing credentials?" || die "aborted."
fi

# ---------------------------------------------------------------------------
# 2. Choose the version
# ---------------------------------------------------------------------------

CURRENT="$(current_version)"
[[ -n "$CURRENT" ]] || die "could not read TingraCLIVersion.current from Version.swift."

# The documented scheme: main carries the next version with a -dev suffix, and
# releasing drops the suffix. Off-scheme (a bare number already released), the
# sensible default is the next patch.
if [[ "$CURRENT" == *-dev ]]; then
    DEFAULT="$(strip_dev "$CURRENT")"
else
    DEFAULT="$(next_patch "$CURRENT")"
fi
# Never default to a version that is already tagged.
while tag_exists "v${DEFAULT}"; do DEFAULT="$(next_patch "$DEFAULT")"; done

log "current version: ${CURRENT} (Info.plist: $(plist_version))"

if [[ -n "$REQUESTED_VERSION" ]]; then
    VERSION="$REQUESTED_VERSION"
elif $DRY_RUN; then
    VERSION="$DEFAULT"
else
    [[ -t 0 ]] || die "no terminal for the version prompt — pass --version <x.y.z>."
    read -r -p "Next version [${DEFAULT}]: " reply
    VERSION="${reply:-$DEFAULT}"
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version '${VERSION}' must be MAJOR.MINOR.PATCH with no suffix (a release never carries -dev)."
readonly TAG="v${VERSION}"
tag_exists "$TAG" && die "tag ${TAG} already exists — pick a version that has not shipped."

echo
log "plan:"
echo "  version:  ${CURRENT}  ->  ${VERSION}"
echo "  tag:      ${TAG}  (pushed to ${TINGRA_REPO:-larryaasen/tingra})"
echo "  branch:   ${BRANCH}  (bump commit pushed)"
echo "  tap:      ${TINGRA_TAP_REPO:-larryaasen/homebrew-tingra}"
echo "  artifacts: dist/tingra-cli-${VERSION}-arm64.zip and .pkg"
echo

if $DRY_RUN; then
    log "dry run — nothing was changed."
    exit 0
fi

confirm "Cut and publish ${TAG}?" || die "aborted."

# ---------------------------------------------------------------------------
# 3-4. Bump, commit, push
# ---------------------------------------------------------------------------

# Skipped when already in place, so a re-run after a mid-release failure
# resumes instead of double-bumping.
if [[ "$CURRENT" == "$VERSION" && "$(plist_version)" == "$VERSION" ]]; then
    log "version already at ${VERSION} — skipping the bump."
else
    log "bumping to ${VERSION}"
    write_version "$VERSION"
    git -C "$ROOT" add "$VERSION_SWIFT" "$INFO_PLIST"
    git -C "$ROOT" commit -q -m "tingra-cli ${VERSION}"
    log "committed the version bump."
fi

git -C "$ROOT" push -q origin "$BRANCH"
log "pushed ${BRANCH}."

# ---------------------------------------------------------------------------
# 5. Hand off to release-cli-publish.sh (build, sign, notarize, tag, publish, tap)
# ---------------------------------------------------------------------------

log "handing off to scripts/release-cli-publish.sh ${VERSION}"
echo
"${ROOT}/scripts/release-cli-publish.sh" "$VERSION"

# ---------------------------------------------------------------------------
# 6. Reopen the branch on the next -dev version
# ---------------------------------------------------------------------------

if $DEV_BUMP; then
    DEV_VERSION="$(next_patch "$VERSION")-dev"
    echo
    if confirm "Reopen ${BRANCH} on ${DEV_VERSION}?"; then
        write_version "$DEV_VERSION"
        git -C "$ROOT" add "$VERSION_SWIFT" "$INFO_PLIST"
        git -C "$ROOT" commit -q -m "Bumped tingra-cli to ${DEV_VERSION}."
        git -C "$ROOT" push -q origin "$BRANCH"
        log "${BRANCH} now on ${DEV_VERSION}."
    fi
fi

echo
log "released ${TAG}."
echo "  verify:  brew update && brew upgrade tingra-cli && tingra-cli version"
echo "  re-register the daemon after upgrading:  tingra-cli serve --install"
