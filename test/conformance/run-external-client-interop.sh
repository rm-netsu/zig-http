#!/bin/sh
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

"$PYTHON" -c 'import h2' >/dev/null 2>&1 || {
    echo "Python package 'h2' is required for hyper-h2 interoperability" >&2
    exit 2
}

CLIENT_PORT=$(pick_port)
CLIENT_SERVER_LOG=${CLIENT_SERVER_LOG:-"${TMPDIR:-/tmp}/zig-http-client-interop-$$.log"}
"$PYTHON" "$CONFORMANCE_DIR/external_client_server.py" --host 127.0.0.1 --port "$CLIENT_PORT" >"$CLIENT_SERVER_LOG" 2>&1 &
CLIENT_SERVER_PID=$!
cleanup_client_server() {
    kill "$CLIENT_SERVER_PID" 2>/dev/null || true
    wait "$CLIENT_SERVER_PID" 2>/dev/null || true
    if [ "${KEEP_CONFORMANCE_LOG:-0}" != 1 ]; then rm -f "$CLIENT_SERVER_LOG"; fi
}
trap cleanup_client_server EXIT HUP INT TERM

i=0
while [ "$i" -lt 100 ]; do
    if grep -q '^LISTEN ' "$CLIENT_SERVER_LOG" 2>/dev/null; then break; fi
    if ! kill -0 "$CLIENT_SERVER_PID" 2>/dev/null; then
        cat "$CLIENT_SERVER_LOG" >&2 || true
        exit 1
    fi
    i=$((i + 1))
    sleep 0.02
done
if ! grep -q '^LISTEN ' "$CLIENT_SERVER_LOG" 2>/dev/null; then
    echo "hyper-h2 fixture did not become ready" >&2
    cat "$CLIENT_SERVER_LOG" >&2 || true
    exit 1
fi

cd "$ROOT"
"$ZIG" build conformance-client
./zig-out/bin/http2-conformance-client --port "$CLIENT_PORT"
wait "$CLIENT_SERVER_PID"
CLIENT_SERVER_PID=
