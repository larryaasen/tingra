#!/bin/bash
#
#  release-app-package.sh
#  tingra
#
#  Created by Larry Aasen on 2026-11-06.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#
# Builds, signs, verifies, runs, notarizes, staples, and images one of the
# Tingra apps for distribution (docs/RELEASE.md, Decisions 7 and C10). One
# pipeline for both apps, with a per-app table of what differs; only Tingra
# Cameras is wired up so far, and Tingra.app joins it at slice 1.
#
#   archive → export → verify → run → notarize → staple → disk image → sha256
#
# Xcode does the signing (Decision 2, C7): the archive itself is signed with
# the Developer ID Application identity and manual signing, because an
# unsigned archive records no entitlements and its export would ship an app
# that cannot open a camera (RELEASE.md, row B of the Tingra.app spike); the
# export, with the `developer-id` method, applies that method's checks and
# lays the app out for notarization. The export options list names the team,
# so it is generated here at run time and never committed. This script never
# hand-signs an app bundle; the one thing it signs itself is the disk image.
#
# The artifact is one disk image, `<Name>-<version>-arm64.dmg`, holding the
# stapled app and an /Applications symlink; the image is then signed,
# notarized, and stapled on its own, so the app still opens offline after it
# is dragged out (Decision 4, C8).
#
# The app is run before it is notarized (Decision 8, C11): `--version` must
# print the version and exit 0. No signature inspection catches a signature
# the kernel refuses at exec; only running the binary does.
#
# Every copy of the app this run builds is unregistered from Launch Services
# before the script exits, however it exits, so a release cut on a development
# Mac leaves that Mac as it found it (RELEASE.md, "A side effect on the
# development Mac"): a stray registered copy can be the one the system picks.
#
# Environment (signing and notarization are skipped, with a warning, when
# unset — so a run with neither still archives, verifies, runs, and images an
# unsigned development build, which must never be published):
#   TINGRA_SIGN_ID          "Developer ID Application: … (TEAMID)"; the team is
#                           read from its suffix, so no other variable carries it
#   TINGRA_NOTARY_PROFILE   notarytool keychain profile name
#   TINGRA_NOTARY_KEYCHAIN  path to the keychain holding that profile (optional;
#                           notarytool reads the login keychain when unset)
#
# Usage:
#   scripts/release-app-package.sh --app cameras [version]
# The version defaults to the one the built app's Info.plist carries; when it
# is given, the script asserts the app carries exactly that one.
#
# Output: dist/<app>/ holds the staged app and the disk image; nothing else in
# dist/ is touched. Builds go to the app's own git-ignored .build/xcodebuild
# folder, kept between runs so a rebuild is incremental.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

log()  { echo "release-app-package: $*"; }
warn() { echo "release-app-package: WARNING: $*" >&2; }
die()  { echo "release-app-package: ERROR: $*" >&2; exit 1; }

usage() {
    echo "usage: scripts/release-app-package.sh --app cameras [version]" >&2
    exit 2
}

# --- Arguments --------------------------------------------------------------

APP_KEY=""
EXPECTED_VERSION=""
while (( $# > 0 )); do
    case "$1" in
        --app)
            (( $# >= 2 )) || usage
            APP_KEY="$2"
            shift 2
            ;;
        --app=*)
            APP_KEY="${1#--app=}"
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "release-app-package: unknown option '$1'" >&2
            usage
            ;;
        *)
            [[ -z "$EXPECTED_VERSION" ]] || usage
            EXPECTED_VERSION="$1"
            shift
            ;;
    esac
done
[[ -n "$APP_KEY" ]] || usage

# --- The per-app table ------------------------------------------------------
#
# What differs between the apps. Everything below this table is shared.
#   APP_DIR            the app's folder, holding its Xcode project
#   PROJECT, SCHEME    what xcodebuild archives
#   PRODUCT_NAME       the bundle's name without `.app`; it may hold a space,
#                      so every path built from it is quoted
#   BUNDLE_ID          the identifier the bundle must carry
#   DIST_NAME          the folder under dist/ this app's run owns
#   IMAGE_BASE         the disk image's file name before `-<version>-arm64.dmg`
#   VOLUME_NAME        the mounted image's name
#   ENTITLEMENTS       exactly the entitlements the signed app carries, sorted
#   KIT_FRAMEWORKS     the frameworks Contents/Frameworks must hold
case "$APP_KEY" in
    cameras)
        readonly APP_DIR="${ROOT}/apps/tingra-cameras"
        readonly PROJECT="tingra-cameras.xcodeproj"
        readonly SCHEME="tingra-cameras"
        readonly PRODUCT_NAME="Tingra Cameras"
        readonly BUNDLE_ID="com.moonwink.tingra.cameras"
        readonly DIST_NAME="tingra-cameras"
        readonly IMAGE_BASE="Tingra-Cameras"
        readonly VOLUME_NAME="Tingra Cameras"
        # The camera, and library validation off so the camera's CMIOExtension
        # DAL plug-in, signed by another team, can load (the entitlements
        # file's own comment). No profile, so no restricted entitlement.
        readonly ENTITLEMENTS=(
            "com.apple.security.cs.disable-library-validation"
            "com.apple.security.device.camera"
        )
        readonly KIT_FRAMEWORKS=("TingraEventBus" "TingraPlugInKit")
        ;;
    tingra)
        die "Tingra.app is not wired up yet: it needs its provisioning profile, the Notes extension's checks, \
and the fixture bundle's absence (RELEASE.md, Decisions 3 and 8). Only --app cameras is supported."
        ;;
    *)
        die "unknown app '${APP_KEY}'; the apps are: cameras"
        ;;
esac

readonly APP_BUNDLE="${PRODUCT_NAME}.app"
readonly BUILD_DIR="${APP_DIR}/.build/xcodebuild"
readonly DERIVED_DATA="${BUILD_DIR}/DerivedData"
readonly ARCHIVE="${BUILD_DIR}/${SCHEME}.xcarchive"
readonly EXPORT_DIR="${BUILD_DIR}/export"
readonly EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
readonly IMAGE_STAGE="${BUILD_DIR}/image"
readonly MOUNT_POINT="${BUILD_DIR}/mount"
readonly DIST="${ROOT}/dist/${DIST_NAME}"
readonly STAGED_APP="${DIST}/${APP_BUNDLE}"

# --- Cleanup: unregister every copy this run built --------------------------

# Unregisters from Launch Services every registered copy of the app under the
# folders this run writes to: the archive's staging copy in DerivedData, the
# archive, the export, the image's staging folder, the mount point, and the
# staged app in dist/. Launch Services registers a copy when an archive is
# built, an app is stapled, or an image is mounted, so the copies are found by
# asking it rather than by listing paths this script guessed. A path that no
# longer exists is unregistered just the same.
unregister_copies() {
    [[ -x "$LSREGISTER" ]] || return 0
    local registered
    registered="$("$LSREGISTER" -dump 2>/dev/null \
        | sed -nE 's/^path: +(.*\.app)( \(0x[0-9a-f]+\))?$/\1/p' | sort -u)" || return 0
    local path
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        case "$path" in
            "${BUILD_DIR}/"*|"${DIST}/"*)
                "$LSREGISTER" -u "$path" 2>/dev/null || true
                ;;
        esac
    done <<<"$registered"
}

# Detaches the image if this run left it mounted, then unregisters the copies.
# Runs on every exit, so a failed check never leaves a mounted image or a
# registered copy behind.
cleanup() {
    local mounts
    mounts="$(mount)" || mounts=""
    if grep -qF " on ${MOUNT_POINT} " <<<"$mounts"; then
        hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
    fi
    unregister_copies
}
trap cleanup EXIT

# --- Checks shared by every app ---------------------------------------------

# Refuses a Mach-O compiled for coverage. The profile counters live in the
# __llvm_prf_cnts section, and a binary carrying them writes a default.profraw
# into whatever directory it runs from. The load commands are read whole
# before grep sees them: piping otool into `grep -q` under pipefail reports a
# match as a failure whenever grep exits first.
assert_uninstrumented() {
    local load_commands
    load_commands="$(otool -l "$1")"
    if grep -q "sectname __llvm_prf_cnts" <<<"$load_commands"; then
        die "$1 was built with coverage instrumentation, so it would write default.profraw wherever it runs; \
archive the Release configuration, which does not gather coverage"
    fi
}

# Refuses a Mach-O that is not arm64-only or not built for macOS. A project's
# ARCHS setting does not reach its Swift package targets, which is why the
# archive passes ARCHS=arm64 on the command line (RELEASE.md, "ARCHS in the
# xcconfig does not reach the kits").
assert_arm64_macos() {
    local archs build_version
    archs="$(lipo -archs "$1")"
    [[ "$archs" == "arm64" ]] || die "$1 is built for '${archs}'; Tingra ships arm64 only"
    build_version="$(vtool -show-build "$1")"
    [[ "$build_version" == *"platform MACOS"* ]] || die "$1 is not built for macOS: ${build_version}"
}

# Prints one key of the app's Info.plist, or nothing when it is absent.
info_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "${STAGED_APP}/Contents/Info.plist" 2>/dev/null || true
}

# Prints the top-level keys of a property list file, sorted, one per line.
# PlistBuddy prints a dictionary's entries indented by four spaces; the
# entitlements this script compares are flat, so that is all it reads.
plist_keys() {
    /usr/libexec/PlistBuddy -c "Print" "$1" | sed -nE 's/^    ([^ ]+) = .*/\1/p' | sort
}

# Prints one field of `codesign -dvv` for a path ("Authority" prints the
# first, which is the leaf certificate's).
signature_field() {
    local details
    details="$(codesign -dvv "$1" 2>&1)" || return 0
    sed -nE "s/^$2=(.*)$/\1/p" <<<"$details" | head -n1
}

# Prints the CodeDirectory flags of a path's signature, e.g. 0x10000(runtime).
signature_flags() {
    local details
    details="$(codesign -dvv "$1" 2>&1)" || return 0
    sed -nE 's/^CodeDirectory .* flags=([^ ]+) .*/\1/p' <<<"$details" | head -n1
}

# Submits one file to the notary service and waits; dies unless it is
# Accepted. The credential is always a keychain profile; TINGRA_NOTARY_KEYCHAIN
# says which keychain holds it, because notarytool defaults to the login
# keychain and a CI runner's release credentials are not in it.
notarize() {
    local notary_auth=(--keychain-profile "$TINGRA_NOTARY_PROFILE")
    [[ -n "${TINGRA_NOTARY_KEYCHAIN:-}" ]] && notary_auth+=(--keychain "$TINGRA_NOTARY_KEYCHAIN")
    local output
    output="$(xcrun notarytool submit "$1" "${notary_auth[@]}" --wait 2>&1)" || {
        echo "$output" >&2
        die "notarytool could not submit $(basename "$1")"
    }
    echo "$output"
    grep -qE '^ +status: Accepted$' <<<"$output" || die "$(basename "$1") was not accepted by the notary \
service; read its log with 'xcrun notarytool log <id> --keychain-profile ${TINGRA_NOTARY_PROFILE}'"
}

# --- Signing mode -----------------------------------------------------------

SIGNED=0
TEAM=""
if [[ -n "${TINGRA_SIGN_ID:-}" ]]; then
    [[ "$TINGRA_SIGN_ID" == "Developer ID Application: "* ]] || die "TINGRA_SIGN_ID is '${TINGRA_SIGN_ID}'; \
a release is signed with a 'Developer ID Application: … (TEAMID)' identity"
    TEAM="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$TINGRA_SIGN_ID")"
    [[ -n "$TEAM" ]] || die "TINGRA_SIGN_ID does not end in a '(TEAMID)' suffix, which is where the team is read from"
    SIGNED=1
else
    warn "TINGRA_SIGN_ID unset — building an UNSIGNED development app. It has no entitlements, so it cannot open \
a camera, and it must never be published."
fi
NOTARIZE=0
if [[ -n "${TINGRA_NOTARY_PROFILE:-}" ]]; then
    if (( SIGNED )); then
        NOTARIZE=1
    else
        warn "TINGRA_NOTARY_PROFILE is set but TINGRA_SIGN_ID is not — an unsigned app cannot be notarized."
    fi
elif (( SIGNED )); then
    warn "TINGRA_NOTARY_PROFILE unset — the app and image will be signed but NOT notarized or stapled."
fi

# --- 1. Archive -------------------------------------------------------------
#
# For a generic Mac destination, with ARCHS=arm64 on the command line so the
# package frameworks are arm64 too. Signed: manual signing with the Developer
# ID identity and the team from its suffix, all on the command line, so
# nothing about the signer is written into a tracked file. Unsigned:
# CODE_SIGNING_ALLOWED=NO, the shape CI builds; the linker's ad-hoc signature
# then carries no entitlements.
log "archiving ${PRODUCT_NAME} ($( (( SIGNED )) && echo "Developer ID" || echo "unsigned"))…"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$IMAGE_STAGE"
mkdir -p "$BUILD_DIR"
archive_settings=(ARCHS=arm64)
if (( SIGNED )); then
    archive_settings+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=${TINGRA_SIGN_ID}" "DEVELOPMENT_TEAM=${TEAM}")
else
    archive_settings+=(CODE_SIGNING_ALLOWED=NO)
fi
( cd "$APP_DIR" && xcodebuild archive -quiet -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED_DATA" \
    "${archive_settings[@]}" )
[[ -d "${ARCHIVE}/Products/Applications/${APP_BUNDLE}" ]] || die "the archive holds no ${APP_BUNDLE}"

# --- 2. Export --------------------------------------------------------------
#
# Signed only: `developer-id`, manual, the same identity and team. The options
# list is written into the git-ignored build folder, never into a tracked file.
# Unsigned, the archive's own copy is the app.
if (( SIGNED )); then
    log "exporting with the developer-id method…"
    rm -f "$EXPORT_OPTIONS"
    plutil -create xml1 "$EXPORT_OPTIONS"
    plutil -insert method -string developer-id "$EXPORT_OPTIONS"
    plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
    plutil -insert signingCertificate -string "$TINGRA_SIGN_ID" "$EXPORT_OPTIONS"
    plutil -insert teamID -string "$TEAM" "$EXPORT_OPTIONS"
    xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    BUILT_APP="${EXPORT_DIR}/${APP_BUNDLE}"
else
    BUILT_APP="${ARCHIVE}/Products/Applications/${APP_BUNDLE}"
fi
[[ -d "$BUILT_APP" ]] || die "no app at ${BUILT_APP}"

# Stage the app in this app's own folder under dist/, with `ditto`, which
# keeps the frameworks' version symlinks their signatures need. A copy, never
# a move: the exported bundle carries a `com.apple.macl` attribute, which
# protects it from other processes, and the stapler then cannot write its
# ticket into it (error 73, seen 2026-11-06). The copy does not carry the
# attribute. The export is deleted once it is copied, so no second bundle is
# left in the build folder: in a notarized run on 2026-11-06, Launch Services
# registered the export's copy after the exit trap had unregistered
# everything, and a copy that no longer exists cannot be registered.
rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$BUILT_APP" "$STAGED_APP"
(( SIGNED )) && rm -rf "$EXPORT_DIR"

# --- 3. Verify --------------------------------------------------------------
log "verifying the bundle…"

ACTUAL_ID="$(info_value CFBundleIdentifier)"
[[ "$ACTUAL_ID" == "$BUNDLE_ID" ]] || die "the app's bundle identifier is '${ACTUAL_ID}', not ${BUNDLE_ID}"

VERSION="$(info_value CFBundleShortVersionString)"
BUNDLE_VERSION="$(info_value CFBundleVersion)"
[[ -n "$VERSION" ]] || die "the app's Info.plist has no CFBundleShortVersionString"
[[ "$VERSION" == "$BUNDLE_VERSION" ]] || die "CFBundleShortVersionString is '${VERSION}' but CFBundleVersion is \
'${BUNDLE_VERSION}'; both are read from one version line in the app's Tingra.xcconfig"
if [[ -n "$EXPECTED_VERSION" && "$VERSION" != "$EXPECTED_VERSION" ]]; then
    die "the app carries version ${VERSION}, not ${EXPECTED_VERSION}; bump the version line in \
${APP_DIR}/Tingra.xcconfig first"
fi

EXECUTABLE="$(info_value CFBundleExecutable)"
readonly MAIN_BINARY="${STAGED_APP}/Contents/MacOS/${EXECUTABLE}"
[[ -n "$EXECUTABLE" && -f "$MAIN_BINARY" ]] || die "the app's executable '${EXECUTABLE}' is not in Contents/MacOS"

# The icon (C13): the compiled asset catalog, and the .icns it names.
ICON_FILE="$(info_value CFBundleIconFile)"
[[ -n "$ICON_FILE" ]] || die "the app's Info.plist names no CFBundleIconFile; is AppIcon empty?"
[[ "$ICON_FILE" == *.icns ]] || ICON_FILE="${ICON_FILE}.icns"
[[ -f "${STAGED_APP}/Contents/Resources/${ICON_FILE}" ]] || die "the app has no icon at Contents/Resources/${ICON_FILE}"
[[ -f "${STAGED_APP}/Contents/Resources/Assets.car" ]] || die "the app has no compiled asset catalog"

# Every Mach-O the app carries: the main binary and each kit. All must be
# arm64-only macOS code without coverage counters, and every @rpath library
# any of them loads must be in Contents/Frameworks, or the app dies in dyld on
# a user's Mac — which a Debug build hides by finding the kits in DerivedData.
readonly FRAMEWORKS_DIR="${STAGED_APP}/Contents/Frameworks"
IMAGES=("$MAIN_BINARY")
for kit in "${KIT_FRAMEWORKS[@]}"; do
    [[ -d "${FRAMEWORKS_DIR}/${kit}.framework" ]] || die "${kit}.framework is not embedded in Contents/Frameworks; \
the target needs it in its Embed Frameworks phase (C4)"
    IMAGES+=("${FRAMEWORKS_DIR}/${kit}.framework/Versions/A/${kit}")
done
for image in "${IMAGES[@]}"; do
    [[ -f "$image" ]] || die "missing binary ${image}"
    assert_arm64_macos "$image"
    assert_uninstrumented "$image"
    while read -r dependency; do
        [[ -f "${FRAMEWORKS_DIR}/${dependency#@rpath/}" ]] || die "$(basename "$image") loads ${dependency}, \
which is not in Contents/Frameworks"
    done < <(otool -L "$image" | awk '/@rpath\// {print $1}')
done

if (( SIGNED )); then
    codesign --verify --deep --strict "$STAGED_APP" || die "the app's signature does not verify"

    # The app and each kit: the Developer ID authority, this team, the
    # hardened runtime, and a secure timestamp.
    SIGNED_PATHS=("$STAGED_APP")
    for kit in "${KIT_FRAMEWORKS[@]}"; do
        SIGNED_PATHS+=("${FRAMEWORKS_DIR}/${kit}.framework")
    done
    for signed in "${SIGNED_PATHS[@]}"; do
        name="$(basename "$signed")"
        authority="$(signature_field "$signed" Authority)"
        [[ "$authority" == "Developer ID Application: "* ]] || die "${name} is signed by '${authority}', \
not a Developer ID Application identity"
        [[ "$(signature_field "$signed" TeamIdentifier)" == "$TEAM" ]] || die "${name} is not signed by the \
team in TINGRA_SIGN_ID"
        [[ "$(signature_flags "$signed")" == *"runtime"* ]] || die "${name} is not signed with the hardened \
runtime, which notarization requires"
        [[ -n "$(signature_field "$signed" Timestamp)" ]] || die "${name}'s signature has no secure timestamp"
    done

    # Exactly the expected entitlements — none missing, none extra, and in
    # particular no get-task-allow, which a development signature carries
    # and notarization refuses. Compared after parsing, never as text.
    ENTITLEMENTS_FILE="${BUILD_DIR}/entitlements.plist"
    codesign -d --entitlements - --xml "$STAGED_APP" >"$ENTITLEMENTS_FILE" 2>/dev/null \
        || die "could not read the app's entitlements"
    ACTUAL_ENTITLEMENTS="$(plist_keys "$ENTITLEMENTS_FILE")"
    EXPECTED_ENTITLEMENTS="$(printf '%s\n' "${ENTITLEMENTS[@]}" | sort)"
    [[ "$ACTUAL_ENTITLEMENTS" == "$EXPECTED_ENTITLEMENTS" ]] || die "the app's entitlements are:
${ACTUAL_ENTITLEMENTS:-<none>}
but exactly these were expected:
${EXPECTED_ENTITLEMENTS}"
    for entitlement in "${ENTITLEMENTS[@]}"; do
        [[ "$(/usr/libexec/PlistBuddy -c "Print :${entitlement}" "$ENTITLEMENTS_FILE")" == "true" ]] \
            || die "the entitlement ${entitlement} is not true"
    done
    rm -f "$ENTITLEMENTS_FILE"
    log "signature, team, hardened runtime, timestamp, and entitlements verified."
fi
log "bundle verified: ${BUNDLE_ID} ${VERSION}, arm64, kits embedded, icon present."

# --- 4. Run -----------------------------------------------------------------
#
# `--version` prints the version and exits before the app or the engine
# exists. A verifying signature is not proof of a running binary: the kernel
# kills a process at exec over a signature it refuses, before main, with no
# output and no log entry, and notarization never executes the binary.
#
# It runs a copy, byte for byte the staged app, never the staged app itself.
# Once a bundle whose code the notary service already accepted has run, the
# system protects it from other processes, and the stapler can no longer
# write its ticket into it (error 73, seen 2026-11-06). A release's code is
# new, so its staged app would still staple, but a rerun that rebuilds the
# same code would not.
readonly RUN_DIR="${BUILD_DIR}/run"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
ditto "$STAGED_APP" "${RUN_DIR}/${APP_BUNDLE}"
SMOKE_OUTPUT="$("${RUN_DIR}/${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}" --version 2>&1)" && SMOKE_STATUS=0 \
    || SMOKE_STATUS=$?
rm -rf "$RUN_DIR"
if (( SMOKE_STATUS != 0 )); then
    HINT=""
    # 128+9: SIGKILL, which for a freshly signed app means the kernel refused
    # its signature or an entitlement nothing authorizes.
    (( SMOKE_STATUS == 137 )) && HINT=" The app was SIGKILLed at exec, which for a signed app means the kernel \
refused it: compare its entitlements with the expected ones, and run this script with TINGRA_SIGN_ID unset to \
see whether an unsigned build runs."
    die "the app does not run: '${EXECUTABLE} --version' exited ${SMOKE_STATUS}.${HINT} Output: ${SMOKE_OUTPUT:-<none>}"
fi
[[ "$SMOKE_OUTPUT" == "$VERSION" ]] || die "'${EXECUTABLE} --version' printed '${SMOKE_OUTPUT}', not ${VERSION}"
log "the app runs and reports ${VERSION}."

# --- 5. Notarize and staple the app ------------------------------------------
#
# The app is stapled before it goes into the image, so it still opens offline
# once it has been dragged out of it. The zip is only the notary service's
# envelope and is deleted afterwards.
if (( NOTARIZE )); then
    log "notarizing the app…"
    APP_ZIP="${BUILD_DIR}/${IMAGE_BASE}-notarize.zip"
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$STAGED_APP" "$APP_ZIP"
    notarize "$APP_ZIP"
    rm -f "$APP_ZIP"
    xcrun stapler staple "$STAGED_APP"
    xcrun stapler validate "$STAGED_APP"
    ASSESSMENT="$(spctl --assess --type execute -vv "$STAGED_APP" 2>&1)" \
        || die "Gatekeeper does not accept the stapled app: ${ASSESSMENT}"
    [[ "$ASSESSMENT" == *"source=Notarized Developer ID"* ]] || die "Gatekeeper accepts the app, but not as \
notarized Developer ID code: ${ASSESSMENT}"
    log "app notarized and stapled; Gatekeeper accepts it."
fi

# --- 6. The disk image --------------------------------------------------------
#
# hdiutil alone: the app and an /Applications symlink, no background art.
readonly IMAGE="${DIST}/${IMAGE_BASE}-${VERSION}-arm64.dmg"
log "building $(basename "$IMAGE")…"
mkdir -p "$IMAGE_STAGE"
ditto "$STAGED_APP" "${IMAGE_STAGE}/${APP_BUNDLE}"
ln -s /Applications "${IMAGE_STAGE}/Applications"
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$IMAGE_STAGE" -fs HFS+ -format UDZO -ov "$IMAGE"
rm -rf "$IMAGE_STAGE"

if (( SIGNED )); then
    codesign --sign "$TINGRA_SIGN_ID" --timestamp "$IMAGE"
    codesign --verify --strict "$IMAGE" || die "the disk image's signature does not verify"
fi
if (( NOTARIZE )); then
    log "notarizing the disk image…"
    notarize "$IMAGE"
    xcrun stapler staple "$IMAGE"
    xcrun stapler validate "$IMAGE"
    ASSESSMENT="$(spctl --assess --type open --context context:primary-signature -vv "$IMAGE" 2>&1)" \
        || die "Gatekeeper does not accept the stapled disk image: ${ASSESSMENT}"
    log "disk image notarized and stapled; Gatekeeper accepts it."
fi

# What a user gets: mount the image read-only, out of sight of the Finder,
# and run the app inside it. After notarization its staple must validate
# there too, which shows the image holds the stapled copy.
log "checking the app inside the image…"
mkdir -p "$MOUNT_POINT"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT_POINT" "$IMAGE"
IMAGED_APP="${MOUNT_POINT}/${APP_BUNDLE}"
[[ -d "$IMAGED_APP" ]] || die "the disk image holds no ${APP_BUNDLE}"
[[ -L "${MOUNT_POINT}/Applications" ]] || die "the disk image holds no Applications symlink"
IMAGED_OUTPUT="$("${IMAGED_APP}/Contents/MacOS/${EXECUTABLE}" --version 2>&1)" \
    || die "the app inside the disk image does not run: ${IMAGED_OUTPUT}"
[[ "$IMAGED_OUTPUT" == "$VERSION" ]] || die "the app inside the image reports '${IMAGED_OUTPUT}', not ${VERSION}"
if (( NOTARIZE )); then
    xcrun stapler validate "$IMAGED_APP" >/dev/null || die "the app inside the disk image carries no valid staple"
fi
hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT" 2>/dev/null || true

# --- 7. sha256 ----------------------------------------------------------------
SHA="$(shasum -a 256 "$IMAGE" | awk '{print $1}')"

echo
log "artifacts in ${DIST}:"
echo "  app:    ${STAGED_APP}"
echo "  image:  ${IMAGE}"
echo "  sha256: ${SHA}"
if (( ! SIGNED )); then
    warn "this is an UNSIGNED development build — do not publish it."
elif (( ! NOTARIZE )); then
    warn "this build is signed but NOT notarized — do not publish it."
fi
