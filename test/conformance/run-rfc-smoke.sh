#!/bin/sh
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

"$PYTHON" -c 'import hpack' >/dev/null 2>&1 || {
    echo "Python package 'hpack' is required for the raw-wire conformance smoke tests" >&2
    exit 2
}

start_fixture
"$PYTHON" "$CONFORMANCE_DIR/rfc_h2spec_smoke.py" --host 127.0.0.1 --port "$PORT"
