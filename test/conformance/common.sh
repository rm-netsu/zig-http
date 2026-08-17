#!/bin/sh
set -eu

CONFORMANCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$CONFORMANCE_DIR/../.." && pwd)
ZIG=${ZIG:-zig}
PYTHON=${PYTHON:-python3}

pick_port() {
    if [ -n "${HTTP2_TEST_PORT:-}" ]; then
        printf '%s\n' "$HTTP2_TEST_PORT"
        return
    fi
    "$PYTHON" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

start_fixture() {
    PORT=$(pick_port)
    export PORT
    cd "$ROOT"
    "$ZIG" build conformance-server
    SERVER_LOG=${SERVER_LOG:-"${TMPDIR:-/tmp}/zig-http-conformance-$$.log"}
    export SERVER_LOG
    ./zig-out/bin/http2-conformance-server --port "$PORT" >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    export SERVER_PID

    i=0
    while [ "$i" -lt 100 ]; do
        if grep -q '^LISTEN ' "$SERVER_LOG" 2>/dev/null; then
            return
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            cat "$SERVER_LOG" >&2 || true
            return 1
        fi
        i=$((i + 1))
        sleep 0.02
    done
    echo "conformance fixture did not become ready" >&2
    cat "$SERVER_LOG" >&2 || true
    return 1
}

stop_fixture() {
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [ -n "${SERVER_LOG:-}" ] && [ "${KEEP_CONFORMANCE_LOG:-0}" != 1 ]; then
        rm -f "$SERVER_LOG"
    fi
}

trap stop_fixture EXIT HUP INT TERM
