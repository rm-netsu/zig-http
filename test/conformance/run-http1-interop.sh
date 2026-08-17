#!/bin/sh
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

command -v curl >/dev/null 2>&1 || {
    echo "curl is required for HTTP/1.1 interoperability" >&2
    exit 2
}

PORT=$(pick_port)
SERVER_LOG=${SERVER_LOG:-"${TMPDIR:-/tmp}/zig-http1-conformance-$$.log"}
cd "$ROOT"
"$ZIG" build http1-conformance-server
./zig-out/bin/http1-conformance-server --port "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

i=0
while [ "$i" -lt 100 ]; do
    if grep -q '^LISTEN ' "$SERVER_LOG" 2>/dev/null; then break; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        cat "$SERVER_LOG" >&2 || true
        exit 1
    fi
    i=$((i + 1))
    sleep 0.02
done
if ! grep -q '^LISTEN ' "$SERVER_LOG" 2>/dev/null; then
    echo "HTTP/1 fixture did not become ready" >&2
    cat "$SERVER_LOG" >&2 || true
    exit 1
fi

body=$(curl --http1.1 --silent --show-error --fail --max-time 5 "http://127.0.0.1:$PORT/")
[ "$body" = "zig-http1" ] || {
    echo "curl HTTP/1 interoperability returned unexpected body: $body" >&2
    exit 1
}
echo "curl HTTP/1.1 interoperability: PASS"
"$PYTHON" "$CONFORMANCE_DIR/http1_external.py" --host 127.0.0.1 --port "$PORT"

"$CONFORMANCE_DIR/run-http1-client-interop.sh"
