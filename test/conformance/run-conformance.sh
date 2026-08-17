#!/bin/sh
set -eu
CONFORMANCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

printf '%s\n' '== HTTP/1 interoperability =='
"$CONFORMANCE_DIR/run-http1-interop.sh"

printf '%s\n' '== HTTP/2 RFC smoke =='
"$CONFORMANCE_DIR/run-rfc-smoke.sh"

printf '%s\n' '== HTTP/2 external interoperability =='
"$CONFORMANCE_DIR/run-external-interop.sh"

printf '%s\n' 'conformance aggregate: PASS'
