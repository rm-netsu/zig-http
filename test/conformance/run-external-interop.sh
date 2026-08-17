#!/bin/sh
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

"$PYTHON" -c 'import h2' >/dev/null 2>&1 || {
    echo "Python package 'h2' is required for hyper-h2 interoperability" >&2
    exit 2
}
command -v curl >/dev/null 2>&1 || {
    echo "curl is required for libcurl/libnghttp2 interoperability" >&2
    exit 2
}
curl --version | grep -q 'HTTP2' || {
    echo "curl was built without HTTP/2 support" >&2
    exit 2
}

start_fixture
"$PYTHON" "$CONFORMANCE_DIR/external_interop.py" --host 127.0.0.1 --port "$PORT"
body=$(curl --http2-prior-knowledge --silent --show-error --fail --max-time 5 "http://127.0.0.1:$PORT/")
[ "$body" = "zig-http" ] || {
    echo "curl interoperability returned unexpected body: $body" >&2
    exit 1
}
echo "curl/libnghttp2 interoperability: PASS"

"$CONFORMANCE_DIR/run-external-client-interop.sh"
