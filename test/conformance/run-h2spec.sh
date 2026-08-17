#!/bin/sh
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

H2SPEC=${H2SPEC_BIN:-h2spec}
H2SPEC=$(command -v "$H2SPEC" || true)
if [ -z "$H2SPEC" ]; then
    echo "h2spec is required; install v2.6.0 or set H2SPEC_BIN=/path/to/h2spec" >&2
    exit 2
fi

start_fixture
set -- http2 hpack generic --strict --host 127.0.0.1 --port "$PORT"
if [ -n "${H2SPEC_JUNIT:-}" ]; then
    set -- "$@" --junit-report "$H2SPEC_JUNIT"
fi
"$H2SPEC" "$@"
