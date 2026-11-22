#!/usr/bin/env bash
#
#  test-packages.sh
#  Tingra
#
#  Runs `swift test` in every Swift package of the monorepo (each
#  packages/<Name> with a Tests/ folder, and apps/tingra-cli), or only in the
#  ones named, and reports which passed. Packages are found on disk rather
#  than listed here, so a new package is tested without editing this script.
#  Every package runs even after one does not pass; the script exits nonzero
#  if any did, after printing each such package's full test output.
#
#  The app (apps/tingra-app) is an Xcode project and is not covered: test it
#  with `xcodebuild test`. Neither are the streaming integration tests
#  (scripts/integration-test.sh).
#
#  Usage:
#    scripts/test-packages.sh                       # every package
#    scripts/test-packages.sh TingraHost tingra-cli  # only these, by folder name
#
#  Created by Larry Aasen on 2026-11-22.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#

set -euo pipefail

cd "$(dirname "$0")/.."

# Every Swift package with a test target, as a path from the repository root.
all_packages=()
for manifest in packages/*/Package.swift apps/*/Package.swift; do
    dir=$(dirname "$manifest")
    [[ -d "$dir/Tests" ]] && all_packages+=("$dir")
done

# The packages to test: all of them, or those whose folder names were given.
packages=()
if [[ $# -eq 0 ]]; then
    packages=("${all_packages[@]}")
else
    for name in "$@"; do
        match=""
        for dir in "${all_packages[@]}"; do
            [[ "$(basename "$dir")" == "$name" ]] && match="$dir"
        done
        if [[ -z "$match" ]]; then
            echo "error: no Swift package with tests named '$name'. Choose from:" >&2
            for dir in "${all_packages[@]}"; do echo "  $(basename "$dir")" >&2; done
            exit 2
        fi
        packages+=("$match")
    done
fi

# Each package's test output goes to its own log, shown only if it did not pass.
logs=$(mktemp -d "${TMPDIR:-/tmp}/tingra-test-packages.XXXXXX")
trap 'rm -rf "$logs"' EXIT

not_passed=()
for dir in "${packages[@]}"; do
    name=$(basename "$dir")
    printf '%-28s ' "$name"
    start=$SECONDS
    if (cd "$dir" && swift test) > "$logs/$name.log" 2>&1; then
        echo "passed ($((SECONDS - start)) s)"
    else
        echo "DID NOT PASS ($((SECONDS - start)) s)"
        not_passed+=("$name")
    fi
done

if [[ ${#not_passed[@]} -eq 0 ]]; then
    echo "All ${#packages[@]} packages passed."
    exit 0
fi

for name in "${not_passed[@]}"; do
    echo
    echo "==================== $name ===================="
    cat "$logs/$name.log"
done
echo
echo "error: ${#not_passed[@]} of ${#packages[@]} packages did not pass: ${not_passed[*]}" >&2
exit 1
