#!/usr/bin/env bash
#
#  check-format.sh
#  Tingra
#
#  Verifies formatting for CI: fails (exit 1) if swift-format would change
#  any Swift source file in any package or app, i.e. if format-swift.sh was
#  not run. Checks byte-for-byte against the formatter's output rather than
#  lint diagnostics, so the check enforces exactly what format-swift.sh
#  produces. Never modifies the working tree.
#
#  Created by Larry Aasen on 2026-07-04.
#  Copyright © 2026 Larry Aasen.
#  SPDX-License-Identifier: MIT
#

set -euo pipefail

cd "$(dirname "$0")/.."

status=0
while IFS= read -r -d '' file; do
    if ! cmp -s "$file" <(xcrun swift-format format --configuration .swift-format "$file"); then
        echo "error: needs formatting: $file — run scripts/format-swift.sh" >&2
        status=1
    fi
done < <(find packages apps -name '*.swift' -not -path '*/.build/*' -print0)

if [[ $status -eq 0 ]]; then
    echo "All Swift sources are formatted."
fi
exit $status
