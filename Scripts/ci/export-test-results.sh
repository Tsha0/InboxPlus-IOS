#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
for RESULT in build/*.xcresult; do
  [[ -d "$RESULT" ]] || continue
  NAME="$(basename "$RESULT" .xcresult)"
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "build/screenshots/$NAME"
  xcrun xcresulttool get test-results summary --path "$RESULT" > "build/$NAME-summary.json"
  xcrun xccov view --report --json "$RESULT" > "build/$NAME-coverage.json"
done
