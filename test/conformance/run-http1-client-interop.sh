#!/bin/sh
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

PORT=$(pick_port)
PY_SERVER_LOG=${PY_SERVER_LOG:-"${TMPDIR:-/tmp}/zig-http1-client-interop-$$.log"}
"$PYTHON" "$CONFORMANCE_DIR/external_http1_server.py" --host 127.0.0.1 --port "$PORT" >"$PY_SERVER_LOG" 2>&1 &
PY_SERVER_PID=$!
cleanup_python_server() {
    if [ -n "${PY_SERVER_PID:-}" ]; then
        kill "$PY_SERVER_PID" 2>/dev/null || true
        wait "$PY_SERVER_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_CONFORMANCE_LOG:-0}" != 1 ]; then rm -f "$PY_SERVER_LOG"; fi
}
trap cleanup_python_server EXIT HUP INT TERM

i=0
while [ "$i" -lt 100 ]; do
    if grep -q '^LISTEN ' "$PY_SERVER_LOG" 2>/dev/null; then break; fi
    if ! kill -0 "$PY_SERVER_PID" 2>/dev/null; then
        cat "$PY_SERVER_LOG" >&2 || true
        exit 1
    fi
    i=$((i + 1))
    sleep 0.02
done
if ! grep -q '^LISTEN ' "$PY_SERVER_LOG" 2>/dev/null; then
    echo "independent HTTP/1 server did not become ready" >&2
    cat "$PY_SERVER_LOG" >&2 || true
    exit 1
fi

cd "$ROOT"
"$ZIG" build http1-conformance-client
./zig-out/bin/http1-conformance-client --port "$PORT"
wait "$PY_SERVER_PID"
PY_SERVER_PID=
