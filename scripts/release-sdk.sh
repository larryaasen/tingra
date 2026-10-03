#!/bin/bash
#
#  release-sdk.sh
#  TingraPlugInSDK
#
#  Created by Larry Aasen on 2026-09-30.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# Builds TingraPlugInSDK, the binary SDK third parties build host-tier plug-in
# bundles against, and publishes it to its public repo (docs/PLUGINS.md,
# Decisions 28 and 37). The SDK is two arm64 XCFrameworks, TingraPlugInKit and
# TingraEventBus, built with Library Evolution and carrying their
# .swiftinterface, served by a Package.swift of two URL binaryTargets.
#
# What it does, in order:
#   1. Preflight: tools, the toolchain floor, and, to publish, authentication,
#      a clean tree pushed to the remote, and a version not yet published.
#   2. Archive the kit package (row G's recipe), copy each kit's .swiftmodule
#      with its .swiftinterface into the archived framework, and wrap each
#      framework in an XCFramework.
#   3. Verify: an arm64-only macOS slice, the framework install names a bundle
#      binds by, no coverage instrumentation, the interface present, and a
#      probe plug-in that builds against the rendered package with the
#      compiler forced to read the interfaces alone.
#   4. Sign each XCFramework with the Developer ID Application identity and
#      verify it. Notarization does not apply to a library nobody launches.
#   5. Zip each XCFramework and compute its SwiftPM checksum.
#   6. Publish: tag plugin-kit-<x.y.z> and event-bus-<x.y.z> on this repo, push
#      the rendered Package.swift, README.md, and LICENSE to the SDK repo, and
#      release the zips there under the bare version tag, then download them
#      back and check them against the manifest.
#
# The version is PlugInKitVersion.current, and the event bus rides at the same
# number (Decision 37). The script never bumps it: a kit version is an API
# promise, raised in the change that alters the API, and a bundle's Info.plist
# names it.
#
# Without TINGRA_SIGN_ID it builds an unsigned development SDK and publishes
# nothing, as release-cli-package.sh does for the CLI. The development SDK is a
# local package (binaryTargets by path) a bundle can be built against.
#
# Usage:
#   scripts/release-sdk.sh               # build, verify, ask, publish
#   scripts/release-sdk.sh --build-only  # build and verify into dist/sdk, publish nothing
#   scripts/release-sdk.sh --dry-run     # preflight and print the plan, change nothing
#   scripts/release-sdk.sh --yes         # never prompt (this is what CI runs)
#
# Environment:
#   TINGRA_SIGN_ID   "Developer ID Application: … (TEAMID)"; unset builds unsigned
#   TINGRA_SDK_REPO  the SDK repo  (default larryaasen/tingra-plug-in-sdk)
#   TINGRA_REPO      this repo     (default larryaasen/tingra), named in the release notes
#
# Resumable: a run that stops before the SDK repo's release is published can
# be run again. The monorepo tags are reused when they name HEAD, an unpublished
# draft release is replaced, and the zips are rebuilt, so the manifest always
# matches the assets. Once the release is published its tag is final, because
# SwiftPM caches a version by tag.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly KIT_DIR="${ROOT}/packages/TingraPlugInKit"
readonly VERSION_SWIFT="${KIT_DIR}/Sources/TingraPlugInKit/PlugInKitVersion.swift"
readonly TEMPLATE_DIR="${ROOT}/packaging/sdk"
readonly WORKFLOW="${ROOT}/.github/workflows/release-sdk.yml"
readonly OUT="${ROOT}/dist/sdk"
# Where xcodebuild archives, kept between runs so a rebuild is incremental.
# Inside the kit's .build folder, which git already ignores.
readonly BUILD_DIR="${KIT_DIR}/.build/xcodebuild-sdk"
readonly SDK_REPO="${TINGRA_SDK_REPO:-larryaasen/tingra-plug-in-sdk}"
readonly REPO="${TINGRA_REPO:-larryaasen/tingra}"
readonly RELEASE_BRANCH="${TINGRA_RELEASE_BRANCH:-main}"
# The frameworks the SDK carries. Archiving TingraPlugInKit builds both,
# because the kit depends on the event bus.
readonly KITS=("TingraPlugInKit" "TingraEventBus")

log()  { echo "release-sdk: $*"; }
warn() { echo "release-sdk: WARNING: $*" >&2; }
die()  { echo "release-sdk: ERROR: $*" >&2; exit 1; }

DRY_RUN=false
BUILD_ONLY=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=true; shift ;;
        --build-only)  BUILD_ONLY=true; shift ;;
        -y|--yes)      ASSUME_YES=true; shift ;;
        -h|--help)     sed -n '10,58p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "unknown argument '$1' (try --help)." ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Reads PlugInKitVersion.current, the source of truth for the SDK's version.
kit_version() {
    sed -nE 's/.*static let current = PlugInKitVersion\(major: ([0-9]+), minor: ([0-9]+), patch: ([0-9]+)\).*/\1.\2.\3/p' \
        "$VERSION_SWIFT"
}

# Reads the swift-tools-version the kit's manifest declares, which the probe
# plug-in's manifest declares too.
tools_version() {
    sed -nE '1s|// swift-tools-version: *([0-9.]+).*|\1|p' "${KIT_DIR}/Package.swift"
}

# Reads the Xcode version the SDK's workflow pins with DEVELOPER_DIR: the
# toolchain floor (CLAUDE.md, "Toolchain & CI"), and the one place it is set.
toolchain_floor() {
    sed -nE 's|.*DEVELOPER_DIR: /Applications/Xcode_([0-9.]+)\.app/.*|\1|p' "$WORKFLOW" | sed -n 1p
}

# Reads the version of the Xcode that xcodebuild belongs to.
xcode_version() {
    xcodebuild -version 2>/dev/null | sed -nE '/^Xcode /{s/^Xcode ([0-9.]+).*/\1/p;q;}'
}

# Reads the version of the Swift compiler xcodebuild will use.
compiler_version() {
    xcrun swift --version 2>/dev/null | sed -nE '/Swift version/{s/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p;q;}'
}

# Trims a version to MAJOR.MINOR: "27.0.1" -> "27.0".
major_minor() {
    local major minor
    IFS='.' read -r major minor _ <<< "$1"
    echo "${major}.${minor}"
}

# Asks a yes/no question, defaulting to no. A missing tty is an error rather
# than a yes, unless --yes stated the intent up front (the workflow's dispatch
# button is the confirmation in CI).
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

# Prints the commit a monorepo tag names, locally or on the remote, or nothing.
tag_commit() {
    local local_sha remote_sha
    local_sha="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true)"
    if [[ -n "$local_sha" ]]; then
        echo "$local_sha"
        return
    fi
    # An annotated tag lists its object and, as `^{}`, the commit it peels to.
    remote_sha="$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$1" "refs/tags/$1^{}" 2>/dev/null \
        | awk -v tag="refs/tags/$1" '{sha[$2] = $1} END {print (sha[tag "^{}"] != "" ? sha[tag "^{}"] : sha[tag])}')"
    echo "$remote_sha"
}

# Prints "published", "draft", or "none" for the SDK repo's release of a tag.
sdk_release_state() {
    local is_draft
    if ! is_draft="$(gh release view "$1" --repo "$SDK_REPO" --json isDraft --jq .isDraft 2>/dev/null)"; then
        echo "none"
    elif [[ "$is_draft" == "true" ]]; then
        echo "draft"
    else
        echo "published"
    fi
}

# Refuses a Mach-O compiled for coverage, as release-cli-package.sh does: a
# binary carrying __llvm_prf_cnts writes default.profraw wherever it runs.
assert_uninstrumented() {
    local load_commands
    load_commands="$(otool -l "$1")"
    if grep -q "sectname __llvm_prf_cnts" <<<"$load_commands"; then
        die "$1 was built with coverage instrumentation; build with CLANG_COVERAGE_MAPPING=NO"
    fi
}

# Prints a kit zip's SwiftPM checksum once step 5 has computed it, else
# nothing. A variable per kit, since macOS's bash 3.2 has no associative arrays.
checksum() {
    local name="CHECKSUM_${1}"
    echo "${!name:-}"
}

# Renders a template from packaging/sdk, replacing its @TOKEN@ placeholders,
# and refuses a result with any placeholder left.
render() {
    local template="$1" destination="$2"
    sed -e "s|@VERSION@|${VERSION}|g" \
        -e "s|@TINGRA_PLUG_IN_KIT_CHECKSUM@|$(checksum TingraPlugInKit)|g" \
        -e "s|@TINGRA_EVENT_BUS_CHECKSUM@|$(checksum TingraEventBus)|g" \
        -e "s|@SDK_REPO@|${SDK_REPO}|g" \
        "$template" > "$destination"
    if grep -q '@[A-Z_]*@' "$destination"; then
        die "$(basename "$template") still has a placeholder after rendering: $(grep -o '@[A-Z_]*@' "$destination" | head -1)"
    fi
}

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

[[ -f "$VERSION_SWIFT" ]] || die "not found: $VERSION_SWIFT"
for template in Package.swift README.md; do
    [[ -f "${TEMPLATE_DIR}/${template}" ]] || die "SDK template not found: ${TEMPLATE_DIR}/${template}"
done
[[ -f "${ROOT}/LICENSE" ]] || die "not found: ${ROOT}/LICENSE"
command -v xcodebuild >/dev/null || die "xcodebuild is required (Xcode $(toolchain_floor))."
command -v git >/dev/null || die "git is required."

VERSION="$(kit_version)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not read PlugInKitVersion.current from ${VERSION_SWIFT}."
readonly VERSION
readonly KIT_TAG="plugin-kit-${VERSION}"
readonly BUS_TAG="event-bus-${VERSION}"

FLOOR="$(toolchain_floor)"
XCODE="$(xcode_version)"
COMPILER="$(compiler_version)"
TOOLS_VERSION="$(tools_version)"
[[ -n "$FLOOR" ]] || die "could not read the pinned Xcode version from DEVELOPER_DIR in ${WORKFLOW}."
[[ -n "$XCODE" && -n "$COMPILER" && -n "$TOOLS_VERSION" ]] || die "could not read the Xcode, compiler, or tools version."

# Unsigned means a development SDK, never a published one: Xcode flags an
# unsigned XCFramework to everyone who adds the package.
PUBLISH=true
if $BUILD_ONLY; then
    PUBLISH=false
elif [[ -z "${TINGRA_SIGN_ID:-}" ]]; then
    if $ASSUME_YES && ! $DRY_RUN; then
        die "refusing to run unattended without TINGRA_SIGN_ID — an unsigned SDK must never be published. \
Pass --build-only for a development SDK."
    fi
    warn "TINGRA_SIGN_ID unset — building an unsigned development SDK and publishing nothing."
    PUBLISH=false
fi

# The interface records the compiler that wrote it, and an older compiler may
# not read a newer one's. A published SDK is built at the floor, so every
# author on a supported Xcode can build against it.
if [[ "$(major_minor "$XCODE")" != "$(major_minor "$FLOOR")" ]]; then
    warn "this is Xcode ${XCODE} (Swift ${COMPILER}), but the toolchain floor is Xcode ${FLOOR}: an interface \
written by a newer compiler may not build under the floor's. Select the floor's Xcode with DEVELOPER_DIR, as CI does."
    if $PUBLISH && ! $DRY_RUN; then
        $ASSUME_YES && die "refusing to publish unattended an SDK built by Xcode ${XCODE} instead of ${FLOOR}."
        confirm "Publish an SDK built by Xcode ${XCODE} anyway?" || die "aborted."
    fi
fi

SDK_STATE="none"
if $PUBLISH; then
    command -v gh >/dev/null || die "the GitHub CLI (gh) is required — 'brew install gh' then 'gh auth login'."
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'."
    gh repo view "$SDK_REPO" >/dev/null 2>&1 || die "cannot reach the SDK repo ${SDK_REPO} — create it \
(public, empty is fine) and make sure this account or token can write to it."

    BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
    if [[ "$BRANCH" != "$RELEASE_BRANCH" ]]; then
        warn "on branch '${BRANCH}', not '${RELEASE_BRANCH}'."
        $DRY_RUN || confirm "Release the SDK from '${BRANCH}' anyway?" || die "aborted."
    fi

    # The tags must name a committed state that is already on the remote, so
    # anyone can check out the source a published SDK was built from.
    if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
        git -C "$ROOT" status --short >&2
        die "the working tree is dirty — commit or stash the above first."
    fi
    git -C "$ROOT" fetch --quiet origin "$BRANCH" 2>/dev/null || warn "could not fetch origin/${BRANCH}."
    git -C "$ROOT" merge-base --is-ancestor HEAD "origin/${BRANCH}" 2>/dev/null \
        || die "HEAD is not on origin/${BRANCH} — push it first, so the tags name a commit others can fetch."

    HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
    for tag in "$KIT_TAG" "$BUS_TAG"; do
        tagged="$(tag_commit "$tag")"
        if [[ -n "$tagged" && "$tagged" != "$HEAD_SHA" ]]; then
            die "tag ${tag} already names ${tagged:0:12}, not HEAD — kit ${VERSION} has shipped. Raise \
PlugInKitVersion.current in the change that alters the kit's API."
        fi
    done

    SDK_STATE="$(sdk_release_state "$VERSION")"
    [[ "$SDK_STATE" != "published" ]] || die "${SDK_REPO} has already published ${VERSION}, and a published \
tag is final (SwiftPM caches a version by tag). Raise PlugInKitVersion.current for a new SDK."
fi

echo
log "plan:"
echo "  version:   ${VERSION} (PlugInKitVersion.current; the event bus rides at the same number)"
echo "  toolchain: Xcode ${XCODE}, Swift ${COMPILER} (floor: Xcode ${FLOOR})"
# Never the identity itself: its common name carries the Team ID.
if [[ -n "${TINGRA_SIGN_ID:-}" ]]; then
    echo "  signing:   Developer ID Application (TINGRA_SIGN_ID)"
else
    echo "  signing:   unsigned (development SDK)"
fi
echo "  output:    dist/sdk/"
if $PUBLISH; then
    echo "  tags:      ${KIT_TAG}, ${BUS_TAG} on ${REPO} at ${HEAD_SHA:0:12}"
    echo "  SDK repo:  ${SDK_REPO}, release ${VERSION}${SDK_STATE:+ (now: ${SDK_STATE})}"
else
    echo "  publish:   nothing"
fi
echo

if $DRY_RUN; then
    log "dry run — nothing was changed."
    exit 0
fi

if $PUBLISH; then
    confirm "Build and publish TingraPlugInSDK ${VERSION}?" || die "aborted."
fi

# ---------------------------------------------------------------------------
# 2. Archive and assemble the XCFrameworks
# ---------------------------------------------------------------------------

# Row G's recipe (docs/PLUGINS.md). BUILD_LIBRARY_FOR_DISTRIBUTION emits the
# .swiftinterface beside the binary module; SKIP_INSTALL=NO puts both
# frameworks in the archive. Coverage is off for the reason the CLI's
# packaging gives: the scheme Xcode generates for a package gathers it.
# Signing happens below, on the XCFrameworks, with the release identity.
log "archiving the kits…"
readonly ARCHIVE="${BUILD_DIR}/TingraPlugInKit.xcarchive"
rm -rf "$ARCHIVE"
( cd "$KIT_DIR" && xcodebuild archive -quiet -scheme TingraPlugInKit \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$BUILD_DIR" \
    ARCHS=arm64 BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO \
    CLANG_COVERAGE_MAPPING=NO CODE_SIGNING_ALLOWED=NO )

# The archive carries the frameworks without their modules, a known SwiftPM
# gap; the modules are in the archive's build products.
readonly ARCHIVED_FRAMEWORKS="${ARCHIVE}/Products/usr/local/lib"
readonly MODULES_DIR="${BUILD_DIR}/Build/Intermediates.noindex/ArchiveIntermediates/TingraPlugInKit/BuildProductsPath/Release"
readonly WORK="${BUILD_DIR}/assemble"

rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK"

for kit in "${KITS[@]}"; do
    framework="${WORK}/${kit}.framework"
    binary="${framework}/Versions/A/${kit}"
    module="${MODULES_DIR}/${kit}.swiftmodule"
    [[ -d "${ARCHIVED_FRAMEWORKS}/${kit}.framework" ]] || die "the archive holds no ${kit}.framework under \
${ARCHIVED_FRAMEWORKS}; the kits must be dynamic products (docs/PLUGINS.md, Decision 22)"
    [[ -d "$module" ]] || die "no ${kit}.swiftmodule in the archive's build products at ${MODULES_DIR}"
    ditto "${ARCHIVED_FRAMEWORKS}/${kit}.framework" "$framework"

    # The checks a bundle's author cannot make: one arm64 macOS slice (a
    # Swift package offers Mac Catalyst too, and the generic destination
    # matches both), and the install name every Tingra front end loads the
    # kit by, which is what lets a bundle bind to the host's one copy.
    [[ "$(lipo -archs "$binary")" == "arm64" ]] || die "${kit} is built for '$(lipo -archs "$binary")'; \
Tingra ships arm64 only"
    [[ "$(vtool -show-build "$binary")" == *"platform MACOS"* ]] || die "${kit} is not built for macOS"
    install_name="$(otool -D "$binary" | sed -n 2p)"
    [[ "$install_name" == "@rpath/${kit}.framework/Versions/A/${kit}" ]] || die "${kit}'s install name is \
'${install_name}', which no Tingra front end loads it by"
    assert_uninstrumented "$binary"

    # Into the versioned framework's Modules, with the top-level symlink a
    # macOS framework has for each of its directories.
    mkdir -p "${framework}/Versions/A/Modules"
    ditto "$module" "${framework}/Versions/A/Modules/${kit}.swiftmodule"
    ln -s Versions/Current/Modules "${framework}/Modules"
    ls "${framework}/Modules/${kit}.swiftmodule/"*.swiftinterface >/dev/null 2>&1 \
        || die "${kit} has no .swiftinterface; build with BUILD_LIBRARY_FOR_DISTRIBUTION=YES"

    debug_symbols=()
    [[ -d "${ARCHIVE}/dSYMs/${kit}.framework.dSYM" ]] \
        && debug_symbols=(-debug-symbols "${ARCHIVE}/dSYMs/${kit}.framework.dSYM")
    xcodebuild -create-xcframework -framework "$framework" "${debug_symbols[@]+"${debug_symbols[@]}"}" \
        -output "${OUT}/${kit}.xcframework" >/dev/null
    log "assembled ${kit}.xcframework"
done

# ---------------------------------------------------------------------------
# 3. Verify with a probe plug-in built against the development SDK
# ---------------------------------------------------------------------------

# The development SDK: the rendered manifest with each URL binaryTarget turned
# into a path one, beside the XCFrameworks. It is what --build-only hands a
# developer, and what the probe builds against.
readonly DEV_SDK="${OUT}/TingraPlugInSDK"
mkdir -p "$DEV_SDK"
render "${TEMPLATE_DIR}/Package.swift" "${WORK}/Package.swift.url"
perl -0pe 's/name: "(\w+)",\s*url: "[^"]*",\s*checksum: "[^"]*"/name: "$1",\n            path: "$1.xcframework"/g' \
    "${WORK}/Package.swift.url" > "${DEV_SDK}/Package.swift"
render "${TEMPLATE_DIR}/README.md" "${DEV_SDK}/README.md"
cp "${ROOT}/LICENSE" "${DEV_SDK}/LICENSE"
grep -q 'url:' "${DEV_SDK}/Package.swift" && die "the development manifest still names a URL; \
check the binaryTarget layout in ${TEMPLATE_DIR}/Package.swift"

# The probe is the smallest real plug-in: a principal class conforming to
# BundledPlugIn that uses a type from each kit. SWIFT_FORCE_MODULE_LOADING
# makes the compiler ignore the binary .swiftmodule and read only the
# interfaces, as an author's newer compiler must.
readonly PROBE="${WORK}/Probe"
mkdir -p "${PROBE}/Sources/Probe"
cat > "${PROBE}/Package.swift" <<EOF
// swift-tools-version: ${TOOLS_VERSION}
import PackageDescription

let package = Package(
    name: "Probe",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Probe", type: .dynamic, targets: ["Probe"])],
    dependencies: [.package(path: "${DEV_SDK}")],
    targets: [
        .target(name: "Probe", dependencies: [.product(name: "TingraPlugInSDK", package: "TingraPlugInSDK")])
    ]
)
EOF
cat > "${PROBE}/Sources/Probe/Probe.swift" <<'EOF'
import TingraEventBus
import TingraPlugInKit

final class Probe: BundledPlugIn {
    let id = PlugInID(rawValue: "com.moonwink.tingra.sdk-probe")
    let name = "Probe"

    init() {}

    func activate(in context: PlugInContext) async throws {
        context.eventBus.trace(
            "probe.activated", domain: .plugIn, params: ["kit": .string(PlugInKitVersion.current.description)])
    }
}
EOF
for kit in "${KITS[@]}"; do
    cp -R "${OUT}/${kit}.xcframework" "${DEV_SDK}/"
done
log "building a probe plug-in against the interfaces alone…"
( cd "$PROBE" && SWIFT_FORCE_MODULE_LOADING=only-interface swift build -c release --arch arm64 --quiet ) \
    || die "a plug-in does not build against the SDK's interfaces; see the errors above"
PROBE_BINARY="$(find "${PROBE}/.build" -name libProbe.dylib -type f -not -path '*.dSYM/*' | head -1)"
[[ -f "$PROBE_BINARY" ]] || die "the probe built, but its libProbe.dylib was not found under ${PROBE}/.build"
# Read whole before grep sees it: `otool | grep -q` under pipefail reports a
# match as a failure whenever grep exits first.
PROBE_LIBRARIES="$(otool -L "$PROBE_BINARY")"
for kit in "${KITS[@]}"; do
    grep -q "@rpath/${kit}.framework/Versions/A/${kit} " <<<"$PROBE_LIBRARIES" \
        || die "the probe does not link ${kit} by its framework install name"
done
log "the probe builds from the interfaces and links both kits by their framework install names."

# ---------------------------------------------------------------------------
# 4. Sign
# ---------------------------------------------------------------------------

if [[ -n "${TINGRA_SIGN_ID:-}" ]]; then
    log "signing with '${TINGRA_SIGN_ID}'…"
    for kit in "${KITS[@]}"; do
        codesign --force --timestamp --sign "$TINGRA_SIGN_ID" \
            --identifier "com.moonwink.tingra.${kit}" "${OUT}/${kit}.xcframework"
        codesign --verify --strict --verbose=2 "${OUT}/${kit}.xcframework"
        # Verify against the identity named, not just any valid signature.
        authority="$(codesign -dv --verbose=2 "${OUT}/${kit}.xcframework" 2>&1 | sed -n '/^Authority=/{s///p;q;}')"
        [[ "$authority" == Developer\ ID\ Application:* ]] || die "${kit}.xcframework is signed by \
'${authority:-nobody}', not a Developer ID Application identity"
    done
    log "both XCFrameworks are signed and verify."
else
    warn "TINGRA_SIGN_ID unset — the XCFrameworks are unsigned (development use only)."
fi

# ---------------------------------------------------------------------------
# 5. Zip and checksum
# ---------------------------------------------------------------------------

# --norsrc keeps extended attributes out, as for the CLI's zip: ditto would
# store them as AppleDouble `._` files that break a framework's seal once
# extracted.
for kit in "${KITS[@]}"; do
    zip="${OUT}/${kit}-${VERSION}.xcframework.zip"
    ( cd "$OUT" && ditto -c -k --norsrc --keepParent "${kit}.xcframework" "$zip" )
    # Run from the build folder: SwiftPM leaves a .build folder wherever it runs.
    printf -v "CHECKSUM_${kit}" '%s' "$( cd "$WORK" && swift package compute-checksum "$zip" )"
    log "wrote $(basename "$zip")  checksum $(checksum "$kit")"
done

# The SDK repo's files, exactly as they will be pushed.
readonly REPO_FILES="${OUT}/repo"
mkdir -p "$REPO_FILES"
render "${TEMPLATE_DIR}/Package.swift" "${REPO_FILES}/Package.swift"
render "${TEMPLATE_DIR}/README.md" "${REPO_FILES}/README.md"
cp "${ROOT}/LICENSE" "${REPO_FILES}/LICENSE"
swift package --package-path "$REPO_FILES" --scratch-path "${WORK}/dump-package" dump-package >/dev/null \
    || die "the rendered Package.swift does not evaluate; see the errors above"

if ! $PUBLISH; then
    echo
    log "built TingraPlugInSDK ${VERSION} in ${OUT} — nothing was published."
    echo "  development package: ${DEV_SDK}"
    echo "    (add it to a bundle target as a local package to build against it)"
    echo "  release files:       ${REPO_FILES}"
    exit 0
fi

# ---------------------------------------------------------------------------
# 6. Publish
# ---------------------------------------------------------------------------

# 6a. Tag this repo, reusing tags that already name HEAD (preflight refused
#     any that name another commit).
for tag in "$KIT_TAG" "$BUS_TAG"; do
    if git -C "$ROOT" rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
        log "tag ${tag} already names HEAD — reusing it."
    else
        git -C "$ROOT" tag "$tag"
    fi
    git -C "$ROOT" push -q origin "refs/tags/${tag}"
done
log "pushed ${KIT_TAG} and ${BUS_TAG}."

# 6b. Push the SDK repo's files. The repo may be empty before the first
#     release, so its default branch may not exist yet.
CLONE="$(mktemp -d)"
trap 'rm -rf "$CLONE"' EXIT
gh repo clone "$SDK_REPO" "$CLONE" -- --depth 1 >/dev/null 2>&1 \
    || die "could not clone ${SDK_REPO} — make sure this account or token can read and write it."
SDK_BRANCH="$(gh repo view "$SDK_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
SDK_BRANCH="${SDK_BRANCH:-main}"
git -C "$CLONE" checkout -q -B "$SDK_BRANCH"
cp "${REPO_FILES}/Package.swift" "${REPO_FILES}/README.md" "${REPO_FILES}/LICENSE" "$CLONE/"
git -C "$CLONE" add Package.swift README.md LICENSE
if git -C "$CLONE" diff --cached --quiet; then
    log "${SDK_REPO} already holds these files."
else
    # The clone has no identity of its own, so it borrows this repo's, as the
    # CLI's tap commit does. CI sets the Actions bot identity.
    AUTHOR_NAME="$(git -C "$ROOT" config user.name || true)"
    AUTHOR_EMAIL="$(git -C "$ROOT" config user.email || true)"
    [[ -n "$AUTHOR_NAME" && -n "$AUTHOR_EMAIL" ]] || die "git user.name/user.email are unset, so the SDK \
commit has no author — set them, then re-run (the monorepo tags are reused)."
    git -C "$CLONE" -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" \
        commit -q -m "TingraPlugInSDK ${VERSION}"
    git -C "$CLONE" push -q origin "HEAD:${SDK_BRANCH}"
    log "pushed the SDK's files to ${SDK_REPO}."
fi
SDK_SHA="$(git -C "$CLONE" rev-parse HEAD)"

# 6c. Release the zips. A draft makes no tag, so it is safe to replace; the
#     release is published, and its tag made, only once both assets are up.
if [[ "$(sdk_release_state "$VERSION")" == "draft" ]]; then
    log "replacing the unpublished draft of ${VERSION}."
    gh release delete "$VERSION" --repo "$SDK_REPO" --yes
fi
assets=()
for kit in "${KITS[@]}"; do
    assets+=("${OUT}/${kit}-${VERSION}.xcframework.zip")
done
gh release create "$VERSION" "${assets[@]}" --repo "$SDK_REPO" --target "$SDK_SHA" --draft \
    --title "TingraPlugInSDK ${VERSION}" \
    --notes "TingraPlugInKit and TingraEventBus ${VERSION}: arm64 XCFrameworks, built with Library Evolution \
by Xcode ${XCODE} (Swift ${COMPILER}) from ${REPO} at ${HEAD_SHA:0:12} (tags \`${KIT_TAG}\` and \`${BUS_TAG}\`). Add \
\`.package(url: \"https://github.com/${SDK_REPO}\", from: \"${VERSION}\")\` and link \`TingraPlugInSDK\` into a bundle target."
gh release edit "$VERSION" --repo "$SDK_REPO" --draft=false >/dev/null
log "published release ${VERSION} on ${SDK_REPO}."

# 6d. Read the artifacts back, not the log: what SwiftPM downloads must match
#     the checksums the pushed manifest pins.
DOWNLOADS="${CLONE}/downloads"
mkdir -p "$DOWNLOADS"
gh release download "$VERSION" --repo "$SDK_REPO" --dir "$DOWNLOADS" --pattern '*.xcframework.zip'
for kit in "${KITS[@]}"; do
    got="$( cd "$DOWNLOADS" && swift package compute-checksum "${kit}-${VERSION}.xcframework.zip" )"
    [[ "$got" == "$(checksum "$kit")" ]] || die "the published ${kit} zip has checksum ${got}, but the \
manifest pins $(checksum "$kit")"
    grep -q "$got" "${CLONE}/Package.swift" || die "the pushed Package.swift does not pin ${kit}'s checksum"
done
log "the published zips match the manifest's checksums."

echo
log "released TingraPlugInSDK ${VERSION}."
echo "  use:  .package(url: \"https://github.com/${SDK_REPO}\", from: \"${VERSION}\")"
