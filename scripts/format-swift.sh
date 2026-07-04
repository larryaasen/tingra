#!/usr/bin/env bash
#
#  format-swift.sh
#  Tingra
#
#  Formats every Swift source file in the monorepo in place, using the
#  toolchain's swift-format and the root .swift-format configuration.
#  Covers every package and app (packages/*, apps/*), skipping build
#  products and dependency checkouts (.build).
#
#  Created by Larry Aasen on 2026-07-04.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#

set -euo pipefail

cd "$(dirname "$0")/.."

find packages apps -name '*.swift' -not -path '*/.build/*' -print0 \
    | xargs -0 xcrun swift-format format --in-place --parallel --configuration .swift-format

echo "Formatted all Swift sources in packages/ and apps/."
