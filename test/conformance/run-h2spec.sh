#!/bin/sh
set -eu
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

H2SPEC=${H2SPEC_BIN:-h2spec}
H2SPEC=$(command -v "$H2SPEC" || true)
if [ -z "$H2SPEC" ]; then
    echo "h2spec is required; install v2.6.0 or set H2SPEC_BIN=/path/to/h2spec" >&2
    exit 2
fi

# h2spec 2.6.0 invokes terminal cleanup code even when stdout is redirected.
# A non-interactive CI environment commonly has no TERM, which can turn an
# otherwise successful run into a spurious non-zero process exit.
if [ -z "${TERM:-}" ]; then
    TERM=dumb
    export TERM
fi

start_fixture
set -- http2 hpack generic --strict --host 127.0.0.1 --port "$PORT"
if [ -n "${H2SPEC_JUNIT:-}" ]; then
    set -- "$@" --junit-report "$H2SPEC_JUNIT"
fi
"$H2SPEC" "$@"
