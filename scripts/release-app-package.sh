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
# pipeline for both apps, Tingra.app and Tingra Cameras, with a per-app table
# of what differs.
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
# Tingra.app carries a restricted entitlement, its keychain group, which only
# a Developer ID provisioning profile authorizes (Decision 3). The profile is
# installed where Xcode finds it and named to the app target alone, through
# TINGRA_APP_PROFILE_SPECIFIER, so its Notes extension and the kit frameworks,
# which would refuse a profile issued for another bundle, are signed without
# one (RELEASE.md, row B of the spike).
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
#   TINGRA_APP_PROFILE      path to the Developer ID .provisionprofile file;
#                           required to sign Tingra.app, unused by Tingra Cameras
#
# Usage:
#   scripts/release-app-package.sh --app tingra|cameras [version]
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
    echo "usage: scripts/release-app-package.sh --app tingra|cameras [version]" >&2
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
#   ENTITLEMENTS       the boolean entitlements the signed app carries, each true
#   PROFILE_ENTITLEMENTS  the entitlements its provisioning profile authorizes;
#                      empty for an app that needs no profile. Together with
#                      ENTITLEMENTS these are exactly the signed app's keys
#   KEYCHAIN_GROUP     the keychain group's suffix, after the App ID prefix;
#                      set only when PROFILE_ENTITLEMENTS names a group
#   KIT_FRAMEWORKS     the frameworks Contents/Frameworks must hold
#   EXTENSIONS         the extensions Contents/Extensions must hold, each
#                      sandboxed, by bundle name without `.appex`
#   EXTENSION_IDS      their bundle identifiers, which the cleanup asks
#                      pluginkit about
#   FORBIDDEN_BUNDLES  bundles a development build embeds and a release must not
case "$APP_KEY" in
    tingra)
        readonly APP_DIR="${ROOT}/apps/tingra-app"
        readonly PROJECT="tingra-app.xcodeproj"
        readonly SCHEME="tingra-app"
        readonly PRODUCT_NAME="Tingra"
        readonly BUNDLE_ID="com.moonwink.tingra.app"
        readonly DIST_NAME="tingra-app"
        readonly IMAGE_BASE="Tingra"
        readonly VOLUME_NAME="Tingra"
        # The camera and microphone under the hardened runtime, and library
        # validation off for camera DAL plug-ins and third-party plug-in
        # bundles signed by another team (the entitlements file's own comment).
        readonly ENTITLEMENTS=(
            "com.apple.security.cs.disable-library-validation"
            "com.apple.security.device.audio-input"
            "com.apple.security.device.camera"
        )
        # The keychain group the app's secure storage needs, and the two
        # identifiers an embedded profile adds beside it.
        readonly PROFILE_ENTITLEMENTS=(
            "com.apple.application-identifier"
            "com.apple.developer.team-identifier"
            "keychain-access-groups"
        )
        readonly KEYCHAIN_GROUP="com.moonwink.tingra.shared"
        readonly KIT_FRAMEWORKS=("TingraEventBus" "TingraPlugInKit")
        readonly EXTENSIONS=("TingraNotes")
        readonly EXTENSION_IDS=("com.moonwink.tingra.app.notes")
        # The loader tests' fixture, which only the test target embeds.
        readonly FORBIDDEN_BUNDLES=("FixturePlugIn.tingraplugin")
        ;;
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
        readonly PROFILE_ENTITLEMENTS=()
        readonly KEYCHAIN_GROUP=""
        readonly KIT_FRAMEWORKS=("TingraEventBus" "TingraPlugInKit")
        readonly EXTENSIONS=()
        readonly EXTENSION_IDS=()
        readonly FORBIDDEN_BUNDLES=()
        ;;
    *)
        die "unknown app '${APP_KEY}'; the apps are: tingra, cameras"
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

# Removes from pluginkit every registered copy of the app's extensions under
# the same folders. Unregistering an app from Launch Services does not remove
# its extensions, and an extra Notes copy at the development build's version
# is enough for the system to pick it, unapproved, over the one in Xcode's
# build (RELEASE.md, "A side effect on the development Mac"). As with the
# apps, pluginkit is asked which copies it holds.
unregister_extensions() {
    local extension_id registered path
    for extension_id in ${EXTENSION_IDS[@]+"${EXTENSION_IDS[@]}"}; do
        registered="$(pluginkit -mAvvv -i "$extension_id" 2>/dev/null \
            | sed -nE 's/^[[:space:]]*Path = (.*\.appex)$/\1/p' | sort -u)" || continue
        while IFS= read -r path; do
            [[ -n "$path" ]] || continue
            case "$path" in
                "${BUILD_DIR}/"*|"${DIST}/"*)
                    pluginkit -r "$path" 2>/dev/null || true
                    ;;
            esac
        done <<<"$registered"
    done
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
    unregister_extensions
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

# Prints one key of a bundle's Info.plist, or nothing when it is absent. The
# bundle is the staged app unless a second argument names another.
info_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "${2:-$STAGED_APP}/Contents/Info.plist" 2>/dev/null || true
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

# --- The provisioning profile -------------------------------------------------
#
# Signed, and only for an app whose entitlements need one. TINGRA_APP_PROFILE
# names the Developer ID profile file: locally wherever it was downloaded, in
# CI the file the release workflow decodes from the secret of the same name.
# It is checked against this team and bundle, then installed where Xcode looks
# for profiles, under its own UUID, unless an identical copy is already there.
# The archive and the export then name it to the app alone.
PROFILE_NAME=""
if (( SIGNED )) && (( ${#PROFILE_ENTITLEMENTS[@]} > 0 )); then
    [[ -n "${TINGRA_APP_PROFILE:-}" ]] || die "TINGRA_APP_PROFILE is unset; ${PRODUCT_NAME}.app's keychain group \
needs its Developer ID provisioning profile. Set it to the .provisionprofile file's path (packaging/README.md, \
\"Release secrets\")."
    [[ -f "$TINGRA_APP_PROFILE" ]] || die "TINGRA_APP_PROFILE names '${TINGRA_APP_PROFILE}', which is not a file"
    PROFILE_PLIST="${BUILD_DIR}/profile.plist"
    mkdir -p "$BUILD_DIR"
    security cms -D -i "$TINGRA_APP_PROFILE" >"$PROFILE_PLIST" 2>/dev/null \
        || die "TINGRA_APP_PROFILE is not a signed provisioning profile: ${TINGRA_APP_PROFILE}"
    # Prints one key of the decoded profile, or nothing when it is absent.
    profile_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PROFILE_PLIST" 2>/dev/null || true; }
    PROFILE_NAME="$(profile_value Name)"
    PROFILE_UUID="$(profile_value UUID)"
    PROFILE_TEAM="$(profile_value TeamIdentifier:0)"
    PROFILE_APP_ID="$(profile_value Entitlements:com.apple.application-identifier)"
    PROFILE_ALL_DEVICES="$(profile_value ProvisionsAllDevices)"
    rm -f "$PROFILE_PLIST"
    [[ -n "$PROFILE_NAME" && -n "$PROFILE_UUID" ]] || die "the profile in TINGRA_APP_PROFILE has no name or UUID"
    [[ "$PROFILE_TEAM" == "$TEAM" ]] || die "the profile '${PROFILE_NAME}' belongs to another team than \
TINGRA_SIGN_ID's"
    [[ "$PROFILE_APP_ID" == *".${BUNDLE_ID}" ]] || die "the profile '${PROFILE_NAME}' is issued for another App ID \
than ${BUNDLE_ID}"
    [[ "$PROFILE_ALL_DEVICES" == "true" ]] || die "the profile '${PROFILE_NAME}' is not a Developer ID profile \
(it lists devices); create one of the Developer ID type for ${BUNDLE_ID}"
    PROFILES_DIR="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
    INSTALLED_PROFILE="${PROFILES_DIR}/${PROFILE_UUID}.provisionprofile"
    if ! cmp -s "$TINGRA_APP_PROFILE" "$INSTALLED_PROFILE"; then
        mkdir -p "$PROFILES_DIR"
        cp "$TINGRA_APP_PROFILE" "$INSTALLED_PROFILE"
        log "installed the provisioning profile '${PROFILE_NAME}' for Xcode."
    fi
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
    # Read by the app target alone; PROVISIONING_PROFILE_SPECIFIER itself would
    # reach every target, and the extension and kits refuse the app's profile.
    if [[ -n "$PROFILE_NAME" ]]; then
        archive_settings+=("TINGRA_APP_PROFILE_SPECIFIER=${PROFILE_NAME}")
    fi
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
    # The per-bundle profile map: the app gets its profile, and every other
    # bundle in it, left out of the map, gets none.
    if [[ -n "$PROFILE_NAME" ]]; then
        /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" \
            -c "Add :provisioningProfiles:${BUNDLE_ID} string \"${PROFILE_NAME}\"" "$EXPORT_OPTIONS"
    fi
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

# Each extension: present, at the app's version (both read TINGRA_VERSION), and
# its binary held to the same rules as the app's.
readonly EXTENSIONS_DIR="${STAGED_APP}/Contents/Extensions"
EXTENSION_PATHS=()
for extension in ${EXTENSIONS[@]+"${EXTENSIONS[@]}"}; do
    extension_path="${EXTENSIONS_DIR}/${extension}.appex"
    [[ -d "$extension_path" ]] || die "${extension}.appex is not embedded in Contents/Extensions; the app target \
needs it in its Embed ExtensionKit Extensions phase"
    extension_version="$(info_value CFBundleShortVersionString "$extension_path")"
    [[ "$extension_version" == "$VERSION" ]] || die "${extension}.appex carries version '${extension_version}', \
not the app's ${VERSION}"
    extension_executable="$(info_value CFBundleExecutable "$extension_path")"
    [[ -n "$extension_executable" ]] || die "${extension}.appex's Info.plist names no CFBundleExecutable"
    EXTENSION_PATHS+=("$extension_path")
    IMAGES+=("${extension_path}/Contents/MacOS/${extension_executable}")
done

# Bundles only a development build or a test embeds.
for forbidden in ${FORBIDDEN_BUNDLES[@]+"${FORBIDDEN_BUNDLES[@]}"}; do
    found="$(find "$STAGED_APP" -name "$forbidden" -print -quit)"
    [[ -z "$found" ]] || die "the app carries ${forbidden}, which only the tests embed: ${found#"${STAGED_APP}/"}"
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
    SIGNED_PATHS+=(${EXTENSION_PATHS[@]+"${EXTENSION_PATHS[@]}"})
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
    EXPECTED_ENTITLEMENTS="$(printf '%s\n' "${ENTITLEMENTS[@]}" ${PROFILE_ENTITLEMENTS[@]+"${PROFILE_ENTITLEMENTS[@]}"} \
        | sort)"
    [[ "$ACTUAL_ENTITLEMENTS" == "$EXPECTED_ENTITLEMENTS" ]] || die "the app's entitlements are:
${ACTUAL_ENTITLEMENTS:-<none>}
but exactly these were expected:
${EXPECTED_ENTITLEMENTS}"
    for entitlement in "${ENTITLEMENTS[@]}"; do
        [[ "$(/usr/libexec/PlistBuddy -c "Print :${entitlement}" "$ENTITLEMENTS_FILE")" == "true" ]] \
            || die "the entitlement ${entitlement} is not true"
    done

    # The profile-authorized entitlements, with their build variables
    # expanded: a literal `$(` reaches the kernel as an entitlement nothing
    # authorizes, and the app is killed at exec (v0.1.1). The keychain group
    # and the application identifier share the App ID prefix the profile
    # grants, which on this account is not the team identifier, so the prefix
    # is read, never assumed.
    if (( ${#PROFILE_ENTITLEMENTS[@]} > 0 )); then
        [[ -f "${STAGED_APP}/Contents/embedded.provisionprofile" ]] || die "the app has no \
Contents/embedded.provisionprofile, so nothing authorizes its keychain group"
        entitlement_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$ENTITLEMENTS_FILE" 2>/dev/null || true; }
        APPLICATION_ID="$(entitlement_value com.apple.application-identifier)"
        [[ "$APPLICATION_ID" != *'$('* && "$APPLICATION_ID" == *".${BUNDLE_ID}" ]] || die "the app's \
application identifier is '${APPLICATION_ID}', not <App ID prefix>.${BUNDLE_ID}"
        APP_ID_PREFIX="${APPLICATION_ID%".${BUNDLE_ID}"}"
        [[ "$(entitlement_value com.apple.developer.team-identifier)" == "$TEAM" ]] || die "the app's team \
identifier entitlement does not name the team in TINGRA_SIGN_ID"
        KEYCHAIN_GROUPS="$(entitlement_value keychain-access-groups | sed -nE 's/^ +([^ ].*)$/\1/p')"
        [[ "$KEYCHAIN_GROUPS" == "${APP_ID_PREFIX}.${KEYCHAIN_GROUP}" ]] || die "the app's keychain groups are:
${KEYCHAIN_GROUPS:-<none>}
but exactly one was expected, ${KEYCHAIN_GROUP} under the App ID prefix the application identifier carries"
        log "the provisioning profile is embedded and the keychain group is expanded."
    fi
    rm -f "$ENTITLEMENTS_FILE"

    # Each extension runs sandboxed: ExtensionKit requires it.
    for extension_path in ${EXTENSION_PATHS[@]+"${EXTENSION_PATHS[@]}"}; do
        codesign -d --entitlements - --xml "$extension_path" >"$ENTITLEMENTS_FILE" 2>/dev/null \
            || die "could not read $(basename "$extension_path")'s entitlements"
        [[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENTITLEMENTS_FILE" 2>/dev/null)" \
            == "true" ]] || die "$(basename "$extension_path") is not sandboxed, and ExtensionKit will not run it"
        rm -f "$ENTITLEMENTS_FILE"
    done
    log "signature, team, hardened runtime, timestamp, and entitlements verified."
fi
log "bundle verified: ${BUNDLE_ID} ${VERSION}, arm64, kits and extensions embedded, icon present."

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
