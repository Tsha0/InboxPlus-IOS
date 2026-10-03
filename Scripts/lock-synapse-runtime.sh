#!/bin/sh
set -eu

python_path=${INBOXPLUS_RUNTIME_PYTHON:-/opt/homebrew/opt/python@3.12/bin/python3.12}
temporary_runtime=$(mktemp -d)
temporary_lock=$(mktemp Runtime/Synapse/requirements.lock.XXXXXX)
trap 'rm -rf "$temporary_runtime"; rm -f "$temporary_lock"' EXIT INT TERM

"$python_path" -m venv "$temporary_runtime/venv"
"$temporary_runtime/venv/bin/python" -m pip install -r Runtime/Synapse/requirements.in
"$temporary_runtime/venv/bin/python" -m pip freeze --all > "$temporary_runtime/requirements.freeze"
LC_ALL=C sort "$temporary_runtime/requirements.freeze" > "$temporary_lock"
mv "$temporary_lock" Runtime/Synapse/requirements.lock
