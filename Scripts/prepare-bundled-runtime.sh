#!/bin/bash
# Build-time dependencies: curl, tar, CMake and Rust (for Synapse's macOS extension).
# INBOXPLUS_RUNTIME_SEED can reuse ONLY the site-packages of an already pinned Python 3.12
# environment; its complete package inventory is checked below. No profile data is copied.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DESTINATION="${1:?usage: prepare-bundled-runtime.sh <Resources/Runtime>}"
CACHE="$REPO_ROOT/build/runtime-cache"
PIN="1bb3e53d231ee2c8881e8daf6426f4dd95bff0dda496af0f3af300357aa998d0"
URL='https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.12.14%2B20260929-aarch64-apple-darwin-install_only_stripped.tar.gz'
[ "$(uname -m)" = arm64 ] || { echo 'This runtime pin currently supports Apple Silicon only.' >&2; exit 1; }
LOCK_HASH="$(shasum -a 256 "$REPO_ROOT/Runtime/Synapse/requirements.lock" | cut -d' ' -f1)"
KEY="$PIN-$LOCK_HASH"
mkdir -p "$CACHE" "$DESTINATION/Synapse"
cp "$REPO_ROOT/Runtime/Synapse/"{runtime-manifest.json,requirements.lock} "$DESTINATION/Synapse/"
if [ ! -f "$CACHE/$KEY/ready" ]; then
  STAGE="$(mktemp -d "$CACHE/stage.XXXXXX")"
  trap 'rm -rf "$STAGE"' EXIT
  curl --fail --location --retry 3 "$URL" -o "$STAGE/python.tar.gz"
  printf '%s  %s\n' "$PIN" "$STAGE/python.tar.gz" | shasum -a 256 --check
  tar -xzf "$STAGE/python.tar.gz" -C "$STAGE"
  PYTHON="$STAGE/python/bin/python3.12"
  if [ -n "${INBOXPLUS_RUNTIME_SEED:-}" ]; then
    rm -rf "$STAGE/python/lib/python3.12/site-packages"
    cp -R "$INBOXPLUS_RUNTIME_SEED/lib/python3.12/site-packages" "$STAGE/python/lib/python3.12/"
  else
    "$PYTHON" -I -m pip install --disable-pip-version-check --no-input -r "$REPO_ROOT/Runtime/Synapse/requirements.lock"
  fi
  "$PYTHON" -I "$REPO_ROOT/Scripts/verify-bundled-python.py" "$REPO_ROOT/Runtime/Synapse/requirements.lock" "$STAGE/python" --prepare
  rm "$STAGE/python.tar.gz"
  touch "$STAGE/ready"
  mv "$STAGE" "$CACHE/$KEY"
  trap - EXIT
fi
# Recheck cached software, so a stale or partially modified cache cannot silently ship.
"$CACHE/$KEY/python/bin/python3.12" -I "$REPO_ROOT/Scripts/verify-bundled-python.py" "$REPO_ROOT/Runtime/Synapse/requirements.lock" "$CACHE/$KEY/python"
rm -rf "$DESTINATION/Python"
cp -R "$CACHE/$KEY/python" "$DESTINATION/Python"
BIN_DIR="$(cd "$REPO_ROOT" && swift build -c release --show-bin-path)"
"$BIN_DIR/InboxPlusRuntimeBundler" libolm "$DESTINATION"
