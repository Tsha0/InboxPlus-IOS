#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM=darwin_arm64; SHA=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
  Darwin-x86_64) PLATFORM=darwin_amd64; SHA=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644 ;;
  Linux-x86_64) PLATFORM=linux_amd64; SHA=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
  *) echo 'Unsupported workflow-lint host' >&2; exit 1 ;;
esac
LINT_TEMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/inbox-lint.XXXXXX")"
trap 'rm -rf "$LINT_TEMP"' EXIT
ARCHIVE="$LINT_TEMP/actionlint.tar.gz"
curl -fsSL --retry 3 "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_$PLATFORM.tar.gz" -o "$ARCHIVE"
ARCHIVE="$ARCHIVE" SHA="$SHA" python3 - <<'PY'
import hashlib,os,pathlib
assert hashlib.sha256(pathlib.Path(os.environ['ARCHIVE']).read_bytes()).hexdigest()==os.environ['SHA'], 'Workflow validator checksum mismatch'
PY
tar -xzf "$ARCHIVE" -C "$LINT_TEMP" actionlint
"$LINT_TEMP/actionlint" -shellcheck= -pyflakes= .github/workflows/*.yml
bash -n Scripts/ci/*.sh
python3 Scripts/ci/test-pipeline.py
